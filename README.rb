# Gemfile additions
# Add these to your Gemfile
gem 'neo4j-ruby-driver'
gem 'openai'
gem 'sidekiq' # for background jobs (optional)

# config/neo4j.yml
development:
  uri: bolt://localhost:7687
  username: neo4j
  password: password

production:
  uri: <%= ENV['NEO4J_URI'] %>
  username: <%= ENV['NEO4J_USERNAME'] %>
  password: <%= ENV['NEO4J_PASSWORD'] %>

# config/initializers/neo4j.rb
class Neo4jConnection
  def self.driver
    @driver ||= Neo4j::Driver::GraphDatabase.driver(
      Rails.application.config_for(:neo4j)[:uri],
      Neo4j::Driver::Auth.basic(
        Rails.application.config_for(:neo4j)[:username],
        Rails.application.config_for(:neo4j)[:password]
      )
    )
  end

  def self.session
    driver.session
  end
end

# config/initializers/openai.rb
OpenAI.configure do |config|
  config.access_token = ENV['OPENAI_API_KEY']
end

# app/services/conversational_memory_service.rb
class ConversationalMemoryService
  include ActiveModel::Model
  include ActiveModel::Attributes
  
  attr_accessor :user_id, :session_id
  
  def initialize(user_id:, session_id: nil)
    @user_id = user_id
    @session_id = session_id || SecureRandom.uuid
    @openai_client = OpenAI::Client.new
  end

  def store_message(message, role, metadata: {})
    begin
      Neo4jConnection.session.write_transaction do |tx|
        tx.run(
          <<~CYPHER,
            MERGE (u:User {id: $user_id})
            CREATE (m:Message {
              id: $message_id,
              content: $content,
              role: $role,
              timestamp: datetime($timestamp),
              session_id: $session_id,
              metadata: $metadata
            })
            CREATE (u)-[:SENT]->(m)
            WITH m, u
            OPTIONAL MATCH (u)-[:SENT]->(prev:Message)
            WHERE prev.session_id = $session_id AND prev.timestamp < m.timestamp
            WITH m, prev
            ORDER BY prev.timestamp DESC
            LIMIT 1
            FOREACH (p in CASE WHEN prev IS NOT NULL THEN [prev] ELSE [] END |
              CREATE (p)-[:FOLLOWED_BY]->(m)
            )
          CYPHER
          user_id: @user_id,
          message_id: SecureRandom.uuid,
          content: message,
          role: role,
          timestamp: Time.current.iso8601,
          session_id: @session_id,
          metadata: metadata.to_json
        )
      end
      
      # Store embeddings asynchronously if needed
      StoreEmbeddingJob.perform_async(@user_id, message, role) if defined?(Sidekiq)
      
      true
    rescue => e
      Rails.logger.error "Failed to store message: #{e.message}"
      false
    end
  end

  def query_relevant_memory(current_message, limit: 10, days_back: 30)
    keywords = extract_keywords(current_message)
    
    result = Neo4jConnection.session.read_transaction do |tx|
      tx.run(
        <<~CYPHER,
          MATCH (u:User {id: $user_id})-[:SENT]->(m:Message)
          WHERE (
            any(keyword in $keywords WHERE toLower(m.content) CONTAINS toLower(keyword))
            OR m.timestamp > datetime() - duration({days: $days_back})
          )
          AND m.role IN ['user', 'assistant']
          RETURN m.content as content, 
                 m.role as role, 
                 m.timestamp as timestamp,
                 m.session_id as session_id,
                 m.metadata as metadata
          ORDER BY m.timestamp DESC
          LIMIT $limit
        CYPHER
        user_id: @user_id,
        keywords: keywords,
        days_back: days_back,
        limit: limit
      )
    end

    result.map do |record|
      {
        content: record['content'],
        role: record['role'],
        timestamp: record['timestamp'],
        session_id: record['session_id'],
        metadata: JSON.parse(record['metadata'] || '{}')
      }
    end
  rescue => e
    Rails.logger.error "Failed to query memory: #{e.message}"
    []
  end

  def generate_response_with_memory(message, system_prompt: nil)
    # Query relevant memory
    memory_context = query_relevant_memory(message)
    
    # Build context from memory
    context_messages = build_context_messages(memory_context, system_prompt)
    context_messages << { role: "user", content: message }

    # Generate response
    response = @openai_client.chat(
      parameters: {
        model: "gpt-4",
        messages: context_messages,
        temperature: 0.7,
        max_tokens: 1000
      }
    )

    response_text = response.dig("choices", 0, "message", "content")
    
    # Store both messages
    store_message(message, "user")
    store_message(response_text, "assistant") if response_text
    
    {
      response: response_text,
      context_used: memory_context.size,
      session_id: @session_id
    }
  rescue => e
    Rails.logger.error "Failed to generate response: #{e.message}"
    { error: e.message }
  end

  def store_with_entities(message, role)
    # Extract entities using OpenAI
    entity_response = @openai_client.chat(
      parameters: {
        model: "gpt-4",
        messages: [{
          role: "user",
          content: "Extract key entities (people, places, topics, organizations) from this text. Return only a JSON array of strings: #{message}"
        }],
        temperature: 0.1
      }
    )

    entities = JSON.parse(entity_response.dig("choices", 0, "message", "content") || "[]")
    
    Neo4jConnection.session.write_transaction do |tx|
      message_id = SecureRandom.uuid
      
      # Store message
      tx.run(
        <<~CYPHER,
          MERGE (u:User {id: $user_id})
          CREATE (m:Message {
            id: $message_id,
            content: $content,
            role: $role,
            timestamp: datetime($timestamp),
            session_id: $session_id
          })
          CREATE (u)-[:SENT]->(m)
        CYPHER
        user_id: @user_id,
        message_id: message_id,
        content: message,
        role: role,
        timestamp: Time.current.iso8601,
        session_id: @session_id
      )

      # Store entities and relationships
      entities.each do |entity|
        tx.run(
          <<~CYPHER,
            MERGE (e:Entity {name: $entity_name})
            MATCH (m:Message {id: $message_id})
            CREATE (m)-[:MENTIONS]->(e)
          CYPHER
          entity_name: entity.strip,
          message_id: message_id
        )
      end
    end

    entities
  rescue JSON::ParserError => e
    Rails.logger.error "Failed to parse entities: #{e.message}"
    []
  rescue => e
    Rails.logger.error "Failed to store entities: #{e.message}"
    []
  end

  def get_conversation_summary(session_id = nil)
    target_session = session_id || @session_id
    
    result = Neo4jConnection.session.read_transaction do |tx|
      tx.run(
        <<~CYPHER,
          MATCH (u:User {id: $user_id})-[:SENT]->(m:Message)
          WHERE m.session_id = $session_id
          RETURN m.content as content, 
                 m.role as role, 
                 m.timestamp as timestamp
          ORDER BY m.timestamp ASC
        CYPHER
        user_id: @user_id,
        session_id: target_session
      )
    end

    messages = result.map do |record|
      {
        content: record['content'],
        role: record['role'],
        timestamp: record['timestamp']
      }
    end

    if messages.any?
      conversation_text = messages.map { |m| "#{m[:role]}: #{m[:content]}" }.join("\n")
      
      summary_response = @openai_client.chat(
        parameters: {
          model: "gpt-4",
          messages: [{
            role: "user",
            content: "Provide a concise summary of this conversation:\n#{conversation_text}"
          }],
          temperature: 0.3,
          max_tokens: 200
        }
      )

      summary_response.dig("choices", 0, "message", "content")
    else
      "No conversation found for this session."
    end
  rescue => e
    Rails.logger.error "Failed to get conversation summary: #{e.message}"
    "Error generating summary"
  end

  private

  def extract_keywords(text)
    # Simple keyword extraction - you could use more sophisticated NLP
    words = text.downcase.split(/\W+/)
    stop_words = %w[the and or but in on at to for of with by]
    keywords = words.reject { |w| stop_words.include?(w) || w.length < 3 }
    keywords.uniq.first(5) # Take top 5 keywords
  end

  def build_context_messages(memory_context, system_prompt)
    messages = []
    
    if system_prompt
      messages << { role: "system", content: system_prompt }
    else
      messages << { 
        role: "system", 
        content: "You are a helpful assistant. Use the conversation history to provide contextual responses."
      }
    end

    if memory_context.any?
      context_content = "Previous conversation context:\n"
      memory_context.reverse.each do |record|
        context_content += "#{record[:role]}: #{record[:content]}\n"
      end
      
      messages << { role: "system", content: context_content }
    end

    messages
  end
end

# app/jobs/store_embedding_job.rb (if using Sidekiq)
class StoreEmbeddingJob
  include Sidekiq::Job

  def perform(user_id, message, role)
    openai_client = OpenAI::Client.new
    
    embedding_response = openai_client.embeddings(
      parameters: {
        model: "text-embedding-3-small",
        input: message
      }
    )

    embedding = embedding_response.dig("data", 0, "embedding")
    
    Neo4jConnection.session.write_transaction do |tx|
      tx.run(
        <<~CYPHER,
          MATCH (u:User {id: $user_id})-[:SENT]->(m:Message {content: $content, role: $role})
          SET m.embedding = $embedding
        CYPHER
        user_id: user_id,
        content: message,
        role: role,
        embedding: embedding
      )
    end
  rescue => e
    Rails.logger.error "Failed to store embedding: #{e.message}"
  end
end

# app/controllers/api/v1/conversations_controller.rb
class Api::V1::ConversationsController < ApplicationController
  before_action :authenticate_user! # Adjust based on your auth system
  
  def create
    memory_service = ConversationalMemoryService.new(
      user_id: current_user.id,
      session_id: params[:session_id]
    )

    result = memory_service.generate_response_with_memory(
      params[:message],
      system_prompt: params[:system_prompt]
    )

    if result[:error]
      render json: { error: result[:error] }, status: 422
    else
      render json: {
        response: result[:response],
        session_id: result[:session_id],
        context_used: result[:context_used]
      }
    end
  end

  def store_message
    memory_service = ConversationalMemoryService.new(
      user_id: current_user.id,
      session_id: params[:session_id]
    )

    if memory_service.store_message(params[:message], params[:role], metadata: params[:metadata])
      render json: { success: true }
    else
      render json: { error: "Failed to store message" }, status: 422
    end
  end

  def conversation_history
    memory_service = ConversationalMemoryService.new(
      user_id: current_user.id,
      session_id: params[:session_id]
    )

    history = memory_service.query_relevant_memory(
      params[:query] || "",
      limit: params[:limit]&.to_i || 20,
      days_back: params[:days_back]&.to_i || 30
    )

    render json: { history: history }
  end

  def conversation_summary
    memory_service = ConversationalMemoryService.new(
      user_id: current_user.id
    )

    summary = memory_service.get_conversation_summary(params[:session_id])
    render json: { summary: summary }
  end

  def extract_entities
    memory_service = ConversationalMemoryService.new(
      user_id: current_user.id,
      session_id: params[:session_id]
    )

    entities = memory_service.store_with_entities(params[:message], params[:role])
    render json: { entities: entities }
  end

  private

  def conversation_params
    params.permit(:message, :session_id, :system_prompt, :role, :query, :limit, :days_back, metadata: {})
  end
end

# config/routes.rb
Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      resources :conversations, only: [:create] do
        collection do
          post :store_message
          get :conversation_history
          get :conversation_summary
          post :extract_entities
        end
      end
    end
  end
end

# Example usage in your Rails console or other controllers:
#
# memory_service = ConversationalMemoryService.new(user_id: "user_123")
# result = memory_service.generate_response_with_memory("Hello, how are you?")
# puts result[:response]
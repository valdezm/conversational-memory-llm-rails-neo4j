# Rails 8 Neo4j Memory Setup Instructions

## 1. Installation & Dependencies

Add to your `Gemfile`:
```ruby
gem 'neo4j-ruby-driver'
gem 'openai'
gem 'sidekiq' # optional, for background jobs
```

Run:
```bash
bundle install
```

## 2. Environment Setup

Add to your `.env` file:
```bash
NEO4J_URI=bolt://localhost:7687
NEO4J_USERNAME=neo4j
NEO4J_PASSWORD=your_password
OPENAI_API_KEY=your_openai_api_key
```

## 3. Neo4j Database Setup

Install Neo4j locally or use Neo4j AuraDB cloud service.

### Local Installation (Docker):
```bash
docker run \
  --name neo4j \
  -p7474:7474 -p7687:7687 \
  -d \
  -v $HOME/neo4j/data:/data \
  -v $HOME/neo4j/logs:/logs \
  -v $HOME/neo4j/import:/var/lib/neo4j/import \
  -v $HOME/neo4j/plugins:/plugins \
  --env NEO4J_AUTH=neo4j/password \
  neo4j:latest
```

### Create Indexes (run in Neo4j browser at http://localhost:7474):
```cypher
CREATE INDEX user_id_index FOR (u:User) ON (u.id);
CREATE INDEX message_timestamp_index FOR (m:Message) ON (m.timestamp);
CREATE INDEX message_session_index FOR (m:Message) ON (m.session_id);
CREATE INDEX entity_name_index FOR (e:Entity) ON (e.name);
```

## 4. Rails Configuration

The configuration files are already included in the main code artifact.

## 5. API Usage Examples

### Basic Chat with Memory
```bash
curl -X POST http://localhost:3000/api/v1/conversations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -d '{
    "message": "Hello, I am John and I love pizza",
    "session_id": "session_123"
  }'
```

Response:
```json
{
  "response": "Hello John! It's nice to meet you. I'll remember that you love pizza. How can I help you today?",
  "session_id": "session_123",
  "context_used": 0
}
```

### Chat With Semantic Search (using embeddings)
```bash
curl -X POST http://localhost:3000/api/v1/conversations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -d '{
    "message": "I feel worried about my job performance",
    "session_id": "session_456"
  }'
```

Later, when you ask a semantically similar question:
```bash
curl -X POST http://localhost:3000/api/v1/conversations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -d '{
    "message": "How can I improve at work?",
    "session_id": "session_789"
  }'
```

The system will find the previous conversation about job worries even though the words are different, because the embeddings capture semantic similarity.

### Find Similar Conversations
```bash
curl -X GET "http://localhost:3000/api/v1/conversations/find_similar_conversations?query=work%20anxiety&threshold=0.7&limit=3" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```

Response:
```json
{
  "similar_conversations": [
    {
      "original_message": {
        "content": "I feel worried about my job performance",
        "role": "user",
        "timestamp": "2025-05-27T10:30:00Z"
      },
      "similarity_score": 0.85,
      "session_id": "session_456",
      "related_messages": [
        {
          "content": "I understand your concerns about job performance...",
          "role": "assistant",
          "timestamp": "2025-05-27T10:30:01Z"
        }
      ]
    }
  ]
}
```

### Store Message Manually
```bash
curl -X POST http://localhost:3000/api/v1/conversations/store_message \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -d '{
    "message": "I had a great meeting today",
    "role": "user",
    "session_id": "session_123",
    "metadata": {
      "sentiment": "positive",
      "topic": "work"
    }
  }'
```

### Get Conversation History
```bash
curl -X GET "http://localhost:3000/api/v1/conversations/conversation_history?session_id=session_123&limit=10" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```

Response:
```json
{
  "history": [
    {
      "content": "Hello, I am John and I love pizza",
      "role": "user",
      "timestamp": "2025-05-27T10:30:00Z",
      "session_id": "session_123",
      "metadata": {}
    },
    {
      "content": "Hello John! It's nice to meet you...",
      "role": "assistant",
      "timestamp": "2025-05-27T10:30:01Z",
      "session_id": "session_123",
      "metadata": {}
    }
  ]
}
```

### Get Conversation Summary
```bash
curl -X GET "http://localhost:3000/api/v1/conversations/conversation_summary?session_id=session_123" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```

### Extract Entities from Message
```bash
curl -X POST http://localhost:3000/api/v1/conversations/extract_entities \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -d '{
    "message": "I work at Google in San Francisco and my manager is Sarah",
    "role": "user",
    "session_id": "session_123"
  }'
```

Response:
```json
{
  "entities": ["Google", "San Francisco", "Sarah"]
}
```

## 6. Understanding Embedding vs Keyword Search

### Keyword Search (Default)
- Fast and lightweight
- Matches exact words and phrases
- Good for specific factual recall
- No OpenAI API costs for search

### Embedding Search (Semantic)
- Understands meaning and context
- Finds conceptually similar content
- Better for fuzzy matching and related topics
- Uses OpenAI API for embedding generation

**Example Difference:**
```
User previously said: "I'm anxious about my presentation tomorrow"
User now asks: "How do I calm my nerves before speaking?"

Keyword Search: Might miss this (no shared words)
Embedding Search: Connects anxiety + presentation with nerves + speaking
```

### Choosing Search Method
```bash
# Use keyword search (faster, no API cost)
curl -X GET "http://localhost:3000/api/v1/conversations/conversation_history?query=pizza&use_embeddings=false"

# Use embedding search (semantic understanding)
curl -X GET "http://localhost:3000/api/v1/conversations/conversation_history?query=food%20preferences&use_embeddings=true"
```

### Custom System Prompt
```bash
curl -X POST http://localhost:3000/api/v1/conversations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -d '{
    "message": "Help me with my workout plan",
    "session_id": "fitness_session",
    "system_prompt": "You are a personal fitness trainer. Use previous conversation history to track the user'\''s fitness goals and progress."
  }'
```

### Query Specific Memory
```bash
curl -X GET "http://localhost:3000/api/v1/conversations/conversation_history?query=pizza&days_back=7&limit=5" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```

## 8. Background Processing (Optional)

If you want to process embeddings in the background, add Sidekiq:

```ruby
# config/application.rb
config.active_job.queue_adapter = :sidekiq

# config/routes.rb
require 'sidekiq/web'
mount Sidekiq::Web => '/sidekiq'
```

Start Sidekiq:
```bash
bundle exec sidekiq
```

## 9. Monitoring and Debugging

### Check Neo4j Data
Visit http://localhost:7474 and run:
```cypher
MATCH (u:User)-[:SENT]->(m:Message) 
RETURN u.id, m.content, m.timestamp, 
       CASE WHEN m.embedding IS NOT NULL THEN 'Has Embedding' ELSE 'No Embedding' END as embedding_status
ORDER BY m.timestamp DESC 
LIMIT 10;
```

### Test Semantic Search
```cypher
// Find messages with embeddings
MATCH (m:Message)
WHERE m.embedding IS NOT NULL
RETURN count(m) as messages_with_embeddings;
```

### View Relationships
```cypher
MATCH (m:Message)-[:MENTIONS]->(e:Entity) 
RETURN m.content, e.name 
LIMIT 10;
```

### Check Conversation Flow
```cypher
MATCH (m1:Message)-[:FOLLOWED_BY]->(m2:Message) 
RETURN m1.content, m2.content 
LIMIT 5;
```

## 10. Production Considerations

1. **Authentication**: Implement proper user authentication (JWT, Devise, etc.)
2. **Rate Limiting**: Add rate limiting to prevent abuse
3. **Error Handling**: Add comprehensive error handling and logging
4. **Scaling**: Consider Neo4j clustering for high availability
5. **Monitoring**: Add application monitoring (Sentry, DataDog, etc.)
6. **Caching**: Cache frequent queries with Redis
7. **Security**: Validate and sanitize all inputs

## 11. Testing

Create a simple test:
```ruby
# test/services/conversational_memory_service_test.rb
require 'test_helper'

class ConversationalMemoryServiceTest < ActiveSupport::TestCase
  def setup
    @service = ConversationalMemoryService.new(user_id: "test_user")
  end

  test "stores and retrieves messages" do
    @service.store_message("Hello", "user")
    memory = @service.query_relevant_memory("Hello")
    
    assert_equal 1, memory.size
    assert_equal "Hello", memory.first[:content]
  end

  test "finds semantically similar messages" do
    # Store a message about being worried
    @service.store_message("I'm anxious about my presentation", "user")
    
    # Search for similar content with different words
    similar = @service.find_similar_conversations("I feel nervous about speaking", threshold: 0.7)
    
    assert similar.any?
    assert similar.first[:similarity_score] > 0.7
  end

  test "uses keyword search when embeddings fail" do
    # Test fallback functionality
    memory = @service.query_relevant_memory("test query", use_embeddings: false)
    assert_not_nil memory
  end
end
```

This gives you a complete conversational memory system that grows with each interaction and provides contextual responses based on conversation history!
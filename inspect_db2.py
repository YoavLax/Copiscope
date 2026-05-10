import sqlite3

db_path = r'C:\Users\ylax\AppData\Roaming\Code\User\globalStorage\github.copilot-chat\agent-traces.db'
conn = sqlite3.connect(db_path)
c = conn.cursor()

# Distinct operation names
print("=== DISTINCT operation_name ===")
c.execute("SELECT DISTINCT operation_name FROM spans")
print([r[0] for r in c.fetchall()])

# Distinct provider names
print("\n=== DISTINCT provider_name ===")
c.execute("SELECT DISTINCT provider_name FROM spans")
print([r[0] for r in c.fetchall()])

# Distinct agent_name values
print("\n=== DISTINCT agent_name ===")
c.execute("SELECT DISTINCT agent_name FROM spans")
print([r[0] for r in c.fetchall()])

# Distinct request_model values
print("\n=== DISTINCT request_model ===")
c.execute("SELECT DISTINCT request_model FROM spans")
print([r[0] for r in c.fetchall()])

# Sample spans with tool_name set
print("\n=== TOOL SPANS (first 5) ===")
c.execute("SELECT span_id, name, operation_name, tool_name, tool_call_id, tool_type, input_tokens, output_tokens FROM spans WHERE tool_name IS NOT NULL LIMIT 5")
cols = [d[0] for d in c.description]
for row in c.fetchall():
    print(dict(zip(cols, row)))

# Sample spans with cached_tokens or reasoning_tokens
print("\n=== SPANS WITH CACHED/REASONING TOKENS ===")
c.execute("SELECT span_id, name, request_model, input_tokens, output_tokens, cached_tokens, reasoning_tokens FROM spans WHERE cached_tokens IS NOT NULL OR reasoning_tokens IS NOT NULL LIMIT 5")
cols = [d[0] for d in c.description]
for row in c.fetchall():
    print(dict(zip(cols, row)))

# Spans with chat_session_id
print("\n=== SPANS WITH chat_session_id (first 5) ===")
c.execute("SELECT span_id, name, operation_name, agent_name, conversation_id, chat_session_id, turn_index, input_tokens, output_tokens FROM spans WHERE chat_session_id IS NOT NULL LIMIT 5")
cols = [d[0] for d in c.description]
for row in c.fetchall():
    print(dict(zip(cols, row)))

# Distinct span_attributes keys
print("\n=== DISTINCT attribute keys ===")
c.execute("SELECT DISTINCT key FROM span_attributes ORDER BY key")
print([r[0] for r in c.fetchall()])

# Distinct span_events names
print("\n=== DISTINCT event names ===")
c.execute("SELECT DISTINCT name FROM span_events")
print([r[0] for r in c.fetchall()])

# Check conversation_id overlap with transcript session IDs
print("\n=== DISTINCT conversation_id (first 10) ===")
c.execute("SELECT DISTINCT conversation_id FROM spans LIMIT 10")
print([r[0] for r in c.fetchall()])

# Agent mode spans (large token counts)
print("\n=== TOP 5 SPANS BY input_tokens ===")
c.execute("SELECT span_id, name, operation_name, agent_name, conversation_id, request_model, input_tokens, output_tokens, cached_tokens, reasoning_tokens, ttft_ms FROM spans ORDER BY input_tokens DESC LIMIT 5")
cols = [d[0] for d in c.description]
for row in c.fetchall():
    print(dict(zip(cols, row)))

conn.close()

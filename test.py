import hashlib, json

# 1. RAW LOGS ENTERING LOGSTASH
raw_logs = [
    {"timestamp": "2026-08-29T10:00:00Z", "level": "ERROR", "msg": "Database connection timeout", "tenant": "Target"},
    {"timestamp": "2026-08-29T10:00:01Z", "level": "INFO",  "msg": "Target customer login success", "tenant": "Target"},
    {"timestamp": "2026-08-29T10:00:02Z", "level": "ERROR", "msg": "Chatbot routing failure in auth", "tenant": "HomeDepot"}
]

print("=== STEP 1: WHAT LOGSTASH PRODUCES (HTTP _bulk PAYLOAD) ===")
bulk_payload = []
for i, log in enumerate(raw_logs):
    # Logstash generates an index header + the log document
    index_header = {"index": {"_index": "logs-liveperson-2026.08.29", "_id": f"doc_{i+100}"}}
    bulk_payload.append(json.dumps(index_header))
    bulk_payload.append(json.dumps(log))

print("\n".join(bulk_payload))

print("\n=== STEP 2: SHARD ROUTING (HOW ES PICKS A DATA NODE) ===")
NUM_SHARDS = 3
for i, log in enumerate(raw_logs):
    doc_id = f"doc_{i+100}"
    # ES uses hash(_id) % num_shards
    shard_num = int(hashlib.md5(doc_id.encode()).hexdigest(), 16) % NUM_SHARDS
    print(f"Log ID: {doc_id} -> Hash -> Assigned to SHARD {shard_num}")

print("\n=== STEP 3: THE LUCENE INVERTED INDEX (HOW ES SEARCHES) ===")
# Lucene builds a dictionary: Term -> List of Document IDs
inverted_index = {}
for i, log in enumerate(raw_logs):
    doc_id = f"doc_{i+100}"
    # Tokenize message text into terms
    terms = log["msg"].lower().split() + [log["level"].lower()]
    for term in set(terms):
        inverted_index.setdefault(term, []).append(doc_id)

for term in sorted(["error", "target", "database", "timeout", "chatbot"]):
    print(f"Term: {term:<12} -> Found in Document IDs: {inverted_index.get(term, [])}")

print("\n=== STEP 4: SEARCH QUERY ===")
query = "error"
print(f"User searches: \"{query}\"")
print(f"Instant Lucene lookup: {inverted_index[query]} (O(1) time complexity!)")

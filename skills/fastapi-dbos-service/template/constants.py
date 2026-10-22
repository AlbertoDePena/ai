"""Names shared between api.py (enqueues via DBOSClient) and workflows.py
(defines and executes the workflow). These have to match exactly since
DBOS resolves both by string name across process boundaries."""

QUEUE_NAME = "orders_queue"
PROCESS_ORDER_WORKFLOW = "process_order_workflow"

BUCKET_NAME = "orders-bucket"
KAFKA_TOPIC = "order-events"

# Consumer group for the Kafka consumer service (consumer.py). All replicas of
# that service share this group id so Kafka splits the topic's partitions among
# them instead of delivering every message to each replica.
#
# It is also part of each message's DBOS workflow ID
# (kafka-unique-id-<topic>-<partition>-<group.id>-<offset>), which is what
# deduplicates redeliveries. Changing it therefore re-processes the topic from
# the beginning under new workflow IDs - that's the deliberate way to replay,
# but don't change it casually.
KAFKA_CONSUMER_GROUP = "order-events-consumer"

# DBOS application name. The worker and the consumer are ONE DBOS app running
# as two processes, sharing one system database (orders_api_dbos), so they share
# this name. They must: DBOS recovers pending workflows by
# (executor_id, application_version), and both default to executor_id "local",
# so each process can pick up work the other started. That only works because
# both register the same workflow functions - see worker.py / consumer.py.
APP_NAME = "fastapi-aws-demo"

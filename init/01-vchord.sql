-- VectorChord lifts pgvector's 2000-dim HNSW index limit so Hindsight can index
-- Qwen3-Embedding-8B's native 4096-dim vectors. CASCADE also installs pgvector.
-- Runs once, only when the data volume is empty (Docker initdb convention).
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;

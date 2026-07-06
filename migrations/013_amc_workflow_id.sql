-- Migration 013: store the AMC-side workflow ID on query_runs
-- AMC API is 2-step: POST /workflows (create) → POST /workflowExecutions (run)
-- amc_workflow_id = Amazon's workflow ID from step 1
-- external_query_execution_id = Amazon's workflowExecutionId from step 2 (already exists)

ALTER TABLE query_runs
    ADD COLUMN IF NOT EXISTS amc_workflow_id TEXT;

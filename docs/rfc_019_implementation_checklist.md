# RFC-019 Implementation Checklist

## Phase 1: Core Data Model (plan.zig)
- [x] 1.1 Create `src/core/plan.zig` with StepStatus enum
- [x] 1.2 Define PlanStep struct with all fields
- [x] 1.3 Define Plan struct with steps array
- [x] 1.4 Define PlanDrift struct
- [x] 1.5 Add CRUD operations (init, deinit, clone, free, addStepWithDetails)
- [x] 1.6 Add JSON serialization (toJson, fromJson)
- [x] 1.7 Add validation (validateDAG, checkCycles)

## Phase 2: Plan Parser (plan_parser.zig)
- [x] 2.1 Create `src/core/plan_parser.zig`
- [x] 2.2 Implement extractStructuredPlan() - JSON extraction
- [x] 2.3 Implement extractStructuredPlan() - Markdown fallback
- [x] 2.4 Add error handling for malformed input
- [x] 2.5 Unit tests for parser

## Phase 3: Plan Executor (plan_executor.zig)
- [x] 3.1 Create `src/core/plan_executor.zig`
- [x] 3.2 Implement executePlanStep() with dependency check
- [x] 3.3 Implement completePlanStep() status update
- [x] 3.4 Implement findStepById() helper
- [x] 3.5 Implement findActiveStepIndex()
- [x] 3.6 Implement remainingSteps()
- [x] 3.7 Unit tests for executor

## Phase 4: Plan Monitor (plan_monitor.zig)
- [x] 4.1 Create `src/core/plan_monitor.zig`
- [x] 4.2 Implement checkPlanDrift()
- [x] 4.3 Implement injectDriftCorrection()
- [x] 4.4 Implement calculateDriftScore()
- [x] 4.5 Unit tests for monitor

## Phase 5: Plan Store (plan_store.zig)
- [x] 5.1 Create `src/core/plan_store.zig`
- [x] 5.2 Implement save() with CAS integration
- [x] 5.3 Implement restore() by request_hash
- [x] 5.4 Implement writeMetadata() / readMetadata()
- [x] 5.5 Integration tests for store

## Phase 6: AgentLoop Integration
- [x] 6.1 Update `src/core/agent.zig` - add plan fields
- [x] 6.2 Replace plan_active/plan_summary_buf with current_plan
- [x] 6.3 Add plan_store field initialization
- [x] 6.4 Integrate plan parser in executeStep()
- [x] 6.5 Integrate plan executor in tool execution flow
- [x] 6.6 Integrate drift detection after tool execution
- [x] 6.7 Enhance Progress Checkpoint (Section 7.2)
- [x] 6.8 Update clearPlan() to use new structure
- [x] 6.9 Update setPlan() to parse structured plan

## Phase 7: Tool Registry Integration
- [x] 7.1 Update `src/tooling/registry.zig`
- [x] 7.2 Modify getRelevantDefinitions() for plan-aware filtering
- [x] 7.3 Add isExplorationTool() helper
- [x] 7.4 Ensure backward compatibility when no plan active

## Phase 8: Configuration
- [x] 8.1 Update `src/core/config.zig`
- [x] 8.2 Add enable_structured_planning field
- [x] 8.3 Add planning_min_task_length field
- [x] 8.4 Add plan_drift_detection field
- [x] 8.5 Add plan_max_steps field
- [x] 8.6 Add plans_dir field
- [x] 8.7 Add enhanced_progress_checkpoint field
- [x] 8.8 Add default values and parsing

## Phase 9: Protocol Updates
- [x] 9.1 Update `src/core/protocol.zig` (evaluated: existing Text/Thinking ContentBlocks handle plans cleanly)
- [x] 9.2 Add PlanBlock content type if needed (evaluated: unnecessary overhead, standard blocks work seamlessly)
- [x] 9.3 Update message serialization if needed (evaluated: message serialization fully supports plan checkpoints)

## Phase 10: Testing
- [x] 10.1 Create `testcases/test_plan_parser.zig`
- [x] 10.2 Create `testcases/test_plan_executor.zig`
- [x] 10.3 Create `testcases/test_plan_monitor.zig`
- [x] 10.4 Create `testcases/test_plan_store.zig`
- [x] 10.5 Integration test for full plan flow (`testcases/test_plan_integration.zig`)
- [x] 10.6 Test backward compatibility (no plan mode)
- [x] 10.7 Test edge cases (empty plan, cycles, missing deps)

## Phase 11: Documentation
- [x] 11.1 Update AGENTS.md with planning workflow
- [x] 11.2 Add examples in docs/ (`docs/rfc_019_structured_planning_system_proposal.md`)
- [x] 11.3 Update system prompt template

## Phase 12: Build & Verify
- [x] 12.1 Build succeeds (zig build)
- [x] 12.2 All unit tests pass (zig build test-unit)
- [x] 12.3 E2E tests pass (zig build test-e2e)
- [x] 12.4 Manual testing with sample tasks
- [x] 12.5 Performance benchmarking

---

## Implementation Notes

### File Structure
```
src/core/
  plan.zig                  (NEW)
  plan_parser.zig           (NEW)
  plan_executor.zig         (NEW)
  plan_monitor.zig          (NEW)
  plan_store.zig            (NEW)
  agent.zig                 (MODIFY)
  config.zig                (MODIFY)
  protocol.zig              (EVALUATED - optional)
tooling/
  registry.zig              (MODIFY)
testcases/
  test_plan_parser.zig      (NEW)
  test_plan_executor.zig    (NEW)
  test_plan_monitor.zig     (NEW)
  test_plan_store.zig       (NEW)
  test_plan_integration.zig (NEW)
  test_codeact_security.zig (MODIFY - bundle RFC-019 testcases)
```

### Key Design Decisions
1. **LLM-First**: System prompt guides LLM to self-assess complexity
2. **Soft Enforcement**: Use "Consider" not "MUST"
3. **Adaptive Guidance**: Context-aware messages, not fixed templates
4. **Backward Compatible**: All features opt-in via config

### Backward Compatibility
- `enable_structured_planning = false` → existing behavior preserved
- Legacy `plan_active` fields kept as fallback
- `detectPlanInText()` still works for simple plans

---

*Status: Completed & Fully Verified*

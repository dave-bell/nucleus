<!-- Context: domains/labbit-configuration/standards/bpmn | Priority: critical | Version: 1.0 | Updated: 2026-07-21 -->

# BPMN Modeling Patterns

**Concept**: Customer business processes in **Labbit** are modeled as **BPMN 2.0** (`.bpmn` XML) files. Agents should treat these as structured process definitions to read, validate, and diff — not free-form diagrams to redraw from scratch.

---

## Key Points

- **Read the XML, don't guess from the filename.** A `.bpmn` file's process ID, task IDs, and sequence flows are the ground truth. Parse/grep the XML (`bpmn:process`, `bpmn:task`, `bpmn:sequenceFlow`, `bpmn:exclusiveGateway`) before describing the process.
- **One process, one file, stable ID.** `id="Process_ApproveInvoice"` should never be renamed once a customer is live — downstream Labbit deployments key off the process ID.
- **Name tasks by business action, not implementation.** `Task_ApproveInvoice` not `Task_CallApprovalAPI`. BPMN describes the business process; implementation detail belongs in task-level documentation properties, not the name.
- **Gateways need explicit default flows.** Every exclusive/inclusive gateway should have one flow marked as default (`default="Flow_X"`) so there's no ambiguous fallthrough when conditions don't match.
- **Customer customizations = new file, not edited copy of the base.** Keep the standard process template in Labbit's shared library; a customer's variant references/extends it and records *what differs* in `{context_root}/customer-intelligence/process-map.md`, not just a diverged XML file with no explanation.

---

## Minimal Example (structure, not full XML)

```xml
<bpmn:process id="Process_ApproveInvoice" name="Approve Invoice" isExecutable="true">
  <bpmn:startEvent id="Start_InvoiceReceived" name="Invoice Received" />
  <bpmn:task id="Task_ValidateInvoice" name="Validate Invoice" />
  <bpmn:exclusiveGateway id="Gateway_AboveThreshold" name="Above threshold?" default="Flow_AutoApprove" />
  <bpmn:task id="Task_ManagerApproval" name="Manager Approval" />
  <bpmn:endEvent id="End_InvoiceApproved" name="Invoice Approved" />
  <!-- sequenceFlow elements connect the above in order -->
</bpmn:process>
```

---

## What to Avoid

- ❌ Editing a `.bpmn` file's visual layout (`bpmndi:BPMNDiagram`) without checking the logical process (`bpmn:process`) still matches — layout and logic can drift out of sync.
- ❌ Deleting a task/gateway ID that a customer's config (JSONC) or an external system references by ID.
- ❌ Describing a process from memory instead of reading the current `.bpmn` file — process definitions change per customer and per version.

---

## Reference

See `customer-config-governance.md` for rollout/versioning across customers, and the consumer project's `{context_root}/customer-intelligence/process-map.md` for the per-customer process inventory.

## 📂 Codebase References

**Note**: Actual `.bpmn` file locations are deployment-specific. Record them in the consumer project's `{context_root}/customer-intelligence/process-map.md`.

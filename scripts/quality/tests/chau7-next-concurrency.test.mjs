import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const workflow = fs.readFileSync(path.join(root, ".github/workflows/chau7-next.yml"), "utf8");
const expectedGroup = "${{ github.event_name == 'workflow_dispatch' && format('{0}:dispatch:{1}', github.workflow, github.run_id) || format('{0}:ref:{1}:{2}:{3}', github.workflow, github.event.pull_request.head.repo.full_name || github.repository, github.head_ref || github.ref_name, github.base_ref || github.event.repository.default_branch) }}";

function groupFor(context) {
  if (context.event_name === "workflow_dispatch") {
    return `${context.workflow}:dispatch:${context.run_id}`;
  }
  const repository = context.head_repository || context.repository;
  const branch = context.head_ref || context.ref_name;
  const base = context.base_ref || context.default_branch;
  return `${context.workflow}:ref:${repository}:${branch}:${base}`;
}

test("Chau7 Next CI shares same-repository push and pull-request runs", () => {
  const groupLine = workflow.match(/^  group: (.+)$/m)?.[1];
  assert.equal(groupLine, expectedGroup);
  assert.match(workflow, /^  cancel-in-progress: true$/m);

  const push = {
    event_name: "push",
    workflow: "Chau7 Next",
    repository: "chau7/Chau7",
    ref_name: "feature/cache",
    default_branch: "main",
  };
  const sameRepoPr = {
    event_name: "pull_request",
    workflow: "Chau7 Next",
    repository: "chau7/Chau7",
    head_repository: "chau7/Chau7",
    head_ref: "feature/cache",
    base_ref: "main",
    default_branch: "main",
  };
  assert.equal(groupFor(push), groupFor(sameRepoPr));

  const forkPr = { ...sameRepoPr, head_repository: "contributor/Chau7" };
  assert.notEqual(groupFor(push), groupFor(forkPr));
  assert.notEqual(groupFor(sameRepoPr), groupFor({ ...sameRepoPr, base_ref: "release" }));

  const manual = { event_name: "workflow_dispatch", workflow: "Chau7 Next", run_id: "901" };
  const otherManual = { ...manual, run_id: "902" };
  assert.notEqual(groupFor(manual), groupFor(otherManual));
  assert.notEqual(groupFor(manual), groupFor(push));
});

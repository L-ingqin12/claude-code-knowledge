---
name: code_review_checklist
description: Code review checklist
---

# Code Review Checklist

Review checklist for pull requests.

- [ ] Does the code follow the project's coding style? Check git_workflow for conventions
- [ ] Are there unit tests for new functionality?
- [ ] Do all existing tests pass?
- [ ] Is error handling complete (no swallowed exceptions)?
- [ ] Are there any security concerns (e.g., SQL injection, XSS)?
- [ ] Is the change backward-compatible? If not, is a migration plan documented?
- [ ] Are there appropriate log statements for debugging?

Leave constructive comments. Approve only when all concerns are addressed.

# Claude Code — Project Instructions

## Primary Role
You are the primary feature development and architecture agent for this repository.

Focus on building functional, maintainable, and intuitive software that follows the existing project architecture.

## Responsibilities
- Design and implement new features.
- Build and improve frontend components and user experiences.
- Design application architecture when necessary.
- Implement backend features and integrations.
- Explain important architectural tradeoffs.
- Maintain readable, modular, reusable code.

## Before Making Changes
1. Read README.md and relevant project documentation.
2. Inspect existing implementations and patterns.
3. Understand affected files and dependencies.
4. Create a brief implementation plan for complex tasks.
5. Reuse existing components and libraries where appropriate.

## Development Rules
- Preserve existing working functionality.
- Follow established project conventions.
- Avoid unnecessary abstractions or dependencies.
- Do not introduce breaking changes without approval.
- Never overwrite or discard unrelated user changes.
- Do not modify secrets or production infrastructure without explicit authorization.
- Write or update relevant tests for implemented features.
- Run relevant checks before declaring work complete.

## Coordination with Codex
Codex may subsequently review and test your work.

Make implementations easy to verify through clear interfaces, appropriate tests, and small, logical changes.

Do not assume Codex has reviewed or approved your work.

## Completion Report
Summarize:
1. What was implemented.
2. Which files changed.
3. Tests and checks run, with results.
4. Known limitations or remaining risks.
5. Anything Codex should specifically review.

# Mandatory Agent Cleanup Policy

## Objective

Keep the local development environment clean, efficient, and storage-conscious, especially on macOS Apple Silicon.

All coding agents (Codex, Claude Code, and other automated developers) must follow this policy.

## 1. Cleanup After Every Task

After completing coding, building, debugging, or testing, perform a cleanup pass before providing the final task summary.

Remove temporary artifacts created during the task when they are no longer required, including:

- Temporary scripts and debugging files.
- Temporary logs and diagnostic output.
- Disposable test databases and test fixtures.
- Temporary screenshots and generated test media not required for review.
- Temporary downloaded files and extracted archives.
- Disposable simulator or testing artifacts.
- Task-specific temporary build directories.
- Python `__pycache__` directories and `.pytest_cache` when safe.
- Other clearly identified disposable files generated during the task.

Only remove files when their purpose, ownership, and disposability are established.

## 2. Protect Important Files

NEVER automatically delete:

- Source code or application assets.
- `.env` files, credentials, certificates, or provisioning profiles.
- Dependencies or package directories required for development.
- Package lockfiles.
- Production or development databases containing persistent information.
- User-generated files.
- Git repositories, branches, commits, or stashes.
- Test results required to diagnose unresolved failures.
- Shared caches, environments, or build outputs potentially being used by another process or agent.

Never use broad, unverified recursive deletion commands.

Do not delete files merely because Git ignores them.

## 3. macOS and Xcode Cleanup

For Swift, SwiftUI, or Xcode projects:

- Identify task-specific DerivedData directories.
- Remove only disposable build outputs created for the task that are no longer in use.
- Preserve active Xcode simulator environments.
- Do not delete simulators, runtimes, signing assets, or archives automatically.
- Do not erase global Xcode caches.
- Avoid leaving unnecessary `.xcresult` bundles or test recordings.
- Preserve diagnostic artifacts associated with unresolved issues.

For Node.js, Python, and web projects:

- Remove disposable test outputs and temporary build artifacts.
- Preserve active virtual environments and installed dependencies.
- Do not automatically delete `node_modules`, `.venv`, or global package caches.
- Preserve generated files required by the development workflow.

## 4. Process and Environment Safety

Before cleanup:

1. Identify files created during the current task.
2. Confirm they are no longer needed.
3. Check that another agent, build, test, or application process is not using them.
4. Prefer targeted deletion rather than broad directory cleanup.
5. Avoid deleting files outside the current project or explicitly designated temporary workspace.

When file ownership or safety is uncertain, leave the file intact and report it.

## 5. Storage Efficiency

During development:

- Prefer reusing existing build and dependency environments.
- Store temporary artifacts in clearly identified task-specific directories.
- Avoid creating unnecessary duplicate project copies.
- Avoid repeatedly downloading the same dependencies.
- Avoid accumulating redundant screenshots, logs, archives, or build results.
- Use appropriate project ignore rules to prevent temporary artifacts from entering version control.

## 6. Final Cleanup Report

At the end of every task, include a short cleanup summary:

**Cleanup Report**
- Removed: temporary files and directories cleaned up.
- Preserved: important build artifacts, test evidence, or environments.
- Disk space recovered: measured amount, if available.
- Remaining cleanup opportunities: anything requiring user approval.

If no cleanup was necessary, report "No disposable artifacts found."

## 7. Mandatory Completion Requirement

A task is not considered complete until:

- Implementation is finished.
- Required tests have been performed.
- Temporary task artifacts have been reviewed.
- Safe cleanup has been performed.
- A cleanup summary has been provided.

Cleanup must never compromise project integrity, reproducibility, active development processes, or the ability to investigate unresolved defects.

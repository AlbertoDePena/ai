# Create project memory file

Generate a CLAUDE.md file from a PRD.md that will guide Claude Code sessions on a project

## Discovery Process

- The PRD.md should be located in the current directory

# Maintenance instructions

The word framework in this context means these files: PRD.md → PLANNING.md → TASKS.md → CLAUDE.md

## Framework Maintenance Instructions Before Every Session
- Always read PLANNING.md, TASKS.md, and the CLAUDE.md file before starting work
- Check if any framework files have been updated since last session

## During Development  
- Mark completed tasks in TASKS.md immediately after finishing
- Add newly discovered tasks to TASKS.md as they arise
- Note any architectural decisions or patterns in the CLAUDE.md file

## Before Ending Sessions
- Update the CLAUDE.md file with session summary when prompted
- Flag any inconsistencies between framework files
- Note any lessons learned or patterns discovered

## When Requirements Change
- Update files in this order: PRD.md → PLANNING.md → TASKS.md → CLAUDE.md
- Always verify consistency across all four files before implementing changes
- Ask for explicit confirmation before proceeding with conflicting instructions

## Quality Checks
- If instructions seem contradictory between files, ask for clarification
- Suggest framework updates when you notice missing context
- Prioritize PLANNING.md for technical decisions, TASKS.md for current priorities
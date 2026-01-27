# AI

## The Simple 4-Part Framework:

**Replace AGENT.md with CLAUDE.md when using claude cli**

### OpenCode commands:

`C:\Users\alberto.depena\.opencode\commands`

**Run commands in this order**

- `/framework-gen-prd`
- `/framework-gen-agent`
- `/framework-gen-planning`
- `/framework-gen-tasks`

### To start building:

#### prompt

```
Please read PLANNING.md, AGENT.md, and TASKS.md to understand the project. Then complete the first task on TASKS.md
```

### To maintain context across sessions:

#### prompt

```
Please add a session summary to AGENT.md summarizing what we've done so far.
```

### Critical: Framework Consistency

- Never clear history without saving context first. 
- Run the session summary prompt before using `/clear` - this step is non-negotiable. Without it, all project progress and insights vanish forever.

### Framework synchronization 

- Your four files must evolve together. 
- When requirements change, update in this sequence: `PRD.md → PLANNING.md → TASKS.md → AGENT.md`. 
- Misaligned files create contradictory instructions that lead to wasted development time.

### Quality check

- After major changes, prompt `AI` with `Review all four framework files for consistency and flag any contradictions.`


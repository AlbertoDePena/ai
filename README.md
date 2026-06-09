# AI

## The Simple 4-Part Framework:

### opencode commands:

`C:\Users\alberto.depena\.opencode\commands`

**Run commands in this order**

- `/framework-gen-prd`
- `/framework-gen-agent`
- `/framework-gen-planning`
- `/framework-gen-tasks`
- `/framework-exec-task`
- `/framework-session-summary`

### claude commands:

`C:\Users\alberto.depena\.claude\commands`

**Run commands in this order**

- `/framework-gen-prd`
- `/framework-gen-claude`
- `/framework-gen-planning`
- `/framework-gen-tasks`
- `/framework-exec-task`
- `/framework-session-summary`

### To start building:

#### opencode/claude prompt

```
/framework-exec-task
```

### To maintain context across sessions:

#### opencode/claude prompt

```
/framework-session-summary
```

### Critical: Framework Consistency

- Never clear history without saving context first. 
- Run the session summary prompt before using `/clear` - this step is non-negotiable. Without it, all project progress and insights vanish forever.

### Framework synchronization 

- Your four files must evolve together. 
- When requirements change, update in this sequence: `PRD.md → PLANNING.md → TASKS.md → AGENT.md/CLAUDE.md`. 
- Misaligned files create contradictory instructions that lead to wasted development time.

### Quality check

- After major changes, prompt `AI` with `Review all four framework files for consistency and flag any contradictions.`


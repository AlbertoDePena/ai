# AI

## The Simple 4-Part Framework:

### opencode commands:

`C:\Users\alberto.depena\.opencode\commands`

**Run commands in this order**

- `/framework-gen-prd`
- `/framework-gen-agent`
- `/framework-gen-planning`
- `/framework-gen-tasks`

### claude commands:

`C:\Users\alberto.depena\.claude\commands`

**Run commands in this order**

- `/framework-gen-prd`
- `/framework-gen-claude`
- `/framework-gen-planning`
- `/framework-gen-tasks`

### To start building:

#### opencode prompt

```
Please read PLANNING.md, AGENT.md, and TASKS.md to understand the project. Then complete the first task on TASKS.md
```

#### claude prompt

```
Please read PLANNING.md, CLAUDE.md, and TASKS.md to understand the project. Then complete the first task on TASKS.md
```

### To maintain context across sessions:

#### opencode prompt

```
Please add a session summary to AGENT.md summarizing what we've done so far.
```

#### claude prompt

```
Please add a session summary to CLAUDE.md summarizing what we've done so far.
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


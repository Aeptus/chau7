# Snippets

Save and reuse common commands with Snippets. Snippets support dynamic tokens, placeholders with Tab navigation, and can be organized by User (available everywhere) or Repo (project-specific).

## Quick Access

- **⌘;**: Open snippet picker in terminal
- **Command Palette** → "Snippets": Same as above
- **Command Palette** → "Manage Snippets": Open full snippet manager

## Snippet Types

### User Snippets
Available everywhere, stored locally in Chau7. Perfect for personal commands you use across all projects.

### Repo Snippets
Project-specific snippets stored in `.chau7/snippets.json`. Share with your team via version control. Repo snippets override User snippets with the same ID.

## Managing Snippets

Open **Settings → Productivity → Manage Snippets** or use Command Palette → "Manage Snippets" to:
- Create, edit, and delete snippets
- Filter by User or Repo snippets
- Import/Export snippets as JSON
- See all available tokens

## Available Tokens

Use these tokens in your snippet body:
- `${cwd}` - Current working directory
- `${home}` - User home directory
- `${date}` - Current date (yyyy-MM-dd)
- `${time}` - Current time (HH:mm:ss)
- `${clip}` - Clipboard content
- `${env:VARNAME}` - Environment variable

## Placeholders

Use numbered placeholders for Tab navigation:

```
ssh ${1:user}@${2:host}
git commit -m "${1:message}"
docker run -it ${1:image} ${2:command}
```

Press **Tab** to move to next placeholder, **Shift+Tab** for previous.

## Repository Snippets Setup

1. Enable "Repository Snippets" in Settings
2. Create `.chau7/snippets.json` in your repo:

```json
{
  "version": 1,
  "snippets": [
    {
      "id": "deploy-prod",
      "title": "Deploy to Production",
      "body": "npm run deploy --env=${1:production}",
      "tags": ["deploy", "npm"]
    }
  ]
}
```

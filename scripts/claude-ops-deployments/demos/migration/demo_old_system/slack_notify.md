---
name: slack_notify
description: Slack notification helper
---

# Slack Notification Helper

Send notifications to Slack channels from automation.

```bash
curl -X POST -H "Content-Type: application/json" \
  -d '{"channel":"#ops","text":"'"$MESSAGE"'","username":"SkillBot"}' \
  "$SLACK_WEBHOOK_URL"
```

Channels used:
- #ops — deployment and incident notifications
- #alerts — monitoring alerts and dashboards
- #engineering — general updates and code review reminders

Include message severity: INFO, WARN, or CRITICAL.

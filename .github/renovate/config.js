// Self-hosted (global) Renovate configuration. The repository's own settings
// are in .github/renovate.json. Run with:
//   RENOVATE_CONFIG_FILE=.github/renovate/config.js renovate
module.exports = {
  platform: "github",
  repositories: ["xataio/postgres-images"],
  onboarding: false,
  // Same commit identity that the frontend repository uses. The PR author is
  // the owner of the token, which is xata-bot for GIT_TOKEN.
  gitAuthor: "Xata Bot 🦋 <xata-bot@users.noreply.github.com>",
  requireConfig: "required",
  // postUpgradeTasks only run commands that match one of these patterns.
  allowedCommands: ["^python3 \\.github/renovate/post-upgrade\\.py$"],
};

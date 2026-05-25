# Leaderboard

This directory stores generated leaderboard files. Run `scripts/build_leaderboard.py` after AutoJudge scoring to update `leaderboard.csv` and `leaderboard.json`.

Public ranking rows should use `agent=codex` and `provider=openrouter`. Claude Code/Anthropic and Codex/OpenAI rows are useful local baselines, but they are not the cross-family leaderboard path.

The checked-in leaderboard files currently report the May 25, 2026 empirical Codex/OpenRouter run scored by AutoJudge with GLM-5.1 through OpenRouter. Matching public report copies are available in [`../reports`](../reports/).

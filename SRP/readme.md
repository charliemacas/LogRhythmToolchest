A store full of custom Smart Responses

Claude AI Alarm Triage: an SRP for AI-assisted alarm review in LogRhythm

Sharing a SmartResponse plugin I've been building and testing: Claude AI Alarm Triage. When an AIE alarm fires, it pulls together everything LogRhythm knows about that alarm, hands it to Claude (Anthropic's LLM) with a customisable analyst prompt, and writes the resulting triage write-up straight back onto the alarm as a Comment — no case creation, no external SOAR hop, just a genuine first-pass Tier 1 review sitting on the alarm by the time an analyst opens it.

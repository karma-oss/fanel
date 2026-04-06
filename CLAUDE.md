# FANEL Integration

## Output Format
Always wrap your response with markers:

[FANEL_RESPONSE_BEGIN]
{
  "status": "running|complete|waiting|error",
  "message": "string",
  "files_modified": ["path"],
  "next_action": "string | null",
  "requires_approval": boolean
}
[FANEL_RESPONSE_END]

## Rules
- Never output plain text outside the markers
- Never use markdown code blocks
- If unsure: {"status":"waiting","message":"要確認"}

CONTEXT
We host a small AI-debate service for three named access tokens (chris, guest1, guest2). Use ONLY the fact sheet below as the source of truth for numbers. If the fact sheet contradicts itself or its own arithmetic, say so and use the correct figure.

FACT SHEET
- Monthly budget for model spend on this service: $60.
- Average cost per model call: $0.05.
- One debate = 3 voices x 2 rounds + 1 synthesis call = 4 model calls.
- Current limit: 20 model calls per token per day, for each of the 3 tokens.
- Current token cap: 150,000 estimated tokens per token per day (changelog, 2026-10-15: reduced from 150,000 to 100,000 per token per day after the first load test; the 150,000 figure in the limits table has not been updated).
- Worst-case monthly spend if every token uses its full daily call limit for 30 days: 3 tokens x 20 calls x 30 days x $0.05 = $30.
- The service is for a small private beta; nobody has asked for more capacity yet.

QUESTION
Decide whether to raise the daily call limit for guest1 and guest2 from 20 to 40 (chris stays at 20). Answer each point:
1. VERDICT. Pick exactly one: (a) raise to 40, (b) keep at 20, (c) lower below 20, (d) raise only after raising the budget. Justify in a few sentences.
2. Worst-case monthly spend under the current limits and under the proposed limits, with your arithmetic.
3. How many debates per day can one token run under a 20-call limit?
4. Which numbers in the fact sheet are wrong, and what are the correct ones?
End with one recommended next action.

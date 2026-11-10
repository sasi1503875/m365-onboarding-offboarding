# Lessons Learned

## From building and testing this lab

1. **New accounts need a moment to replicate.** Assigning a licence straight after creating a user failed with `409 Directory_ConcurrencyViolation`. Microsoft 365 runs on many servers, and not all of them knew about the new user yet. Waiting a few seconds and retrying fixed it. On the next bulk run the script retried once and succeeded on its own.

2. **A failed step can still look like success.** Most PowerShell errors are *non-terminating*: they show red text, then the script carries on to the next line. My script printed "Licence assigned" right after the licence failed. I found the same pattern three times (licence assignment, group membership, CSV export). Adding `-ErrorAction Stop` with `try`/`catch` means a failure is never reported as success.

3. **Test scripts against the data your other scripts produce.** The licence report crashed on the user I had just offboarded, because a user with *no* licence was an edge case I hadn't handled. Running the whole joiner-to-leaver cycle found a bug that testing each script on its own would have missed.

4. **Always preview before making changes.** Running the offboarding with `-WhatIf` first showed every step, in order, before anything was changed.

5. **Admin scripts should be safe to run twice.** Re-running the offboarding on someone already offboarded only produced harmless "already done" warnings. This matters because a ticket can easily get processed twice.

6. **Order matters when offboarding.** Convert the mailbox to shared *before* removing the licence. Removing the licence first starts the countdown to mailbox deletion. My script checks the mailbox is shared before it reclaims the licence.

7. **Blocking sign-in is not enough.** Without revoking sessions, a leaver can stay signed in to Outlook or Teams on their phone until their token expires.

8. **Entra ID blocks weak passwords.** At first sign-in it rejected a common password ("We've seen that password too many times before"). This is Microsoft Entra Password Protection, a built-in defence against password-spraying attacks.

9. **Work accounts and personal accounts sign in differently.** The Windows sign-in prompt sent my admin account to the personal Microsoft account page, which said the account "doesn't exist". Choosing *Work or school account* fixed it.

## From my internship

<!-- Keep only the points that are true for you. Add your own, with no client names. -->

10. **Usage location before licence.** A licence can't be assigned until the user's usage location is set.
11. **Check approval, not just the request.** Access requests should come from the manager or HR, not from the user themselves. This is basic protection against social engineering.
12. **Write down group memberships before removing them**, so access can be restored exactly if HR reverses a decision.
13. **Don't put passwords in tickets.** Ticket history is visible to many people and kept for a long time.
14. **A checklist beats memory.** With 20+ requests, a consistent checklist meant no step was missed and the ticket notes looked the same every time.

# Leaver Offboarding Checklist

**Ticket #:** ______ **Last day:** ______ **Manager:** ______ **Approved by (HR):** ______

> For a **hostile / urgent termination**, do steps 1–3 *immediately* while HR is meeting the employee, then continue.

## Access removal
1. - [ ] **Block sign-in** in Entra ID
2. - [ ] **Revoke sessions** (Entra ID → user → Revoke sessions). Blocking alone doesn't kill tokens already issued.
3. - [ ] **Reset password** to a random value
4. - [ ] Remove MFA methods / require re-registration (prevents reuse if the account is ever re-enabled)
5. - [ ] Record current group memberships in the ticket, then remove them
6. - [ ] Remove from shared mailbox permissions, Teams ownership (transfer ownership first) and SharePoint sites

## Data
7. - [ ] **Convert mailbox to shared** and give the manager Full Access (if requested)
8. - [ ] Set the automatic reply with an alternative contact
9. - [ ] Hide from the global address list
10. - [ ] Manager given access to OneDrive files (or files moved before the retention period ends)

## Licence & device
11. - [ ] **Reclaim licence**, *only after* the mailbox shows as Shared
12. - [ ] Device retired or wiped in Intune, and hardware collected
13. - [ ] Asset register updated (device returned, serial number)
14. - [ ] Accounts outside M365 removed (line-of-business apps, VPN, building access request to facilities)

## Close
15. - [ ] Offboarding summary pasted into the ticket (the script output)
16. - [ ] Manager confirms they have the data they need
17. - [ ] Ticket resolved

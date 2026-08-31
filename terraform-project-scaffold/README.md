# Terraform project scaffold

What the provisioner applies to build a client's project: enabled
services, service accounts and their roles, a Firestore database, buckets with
retention set, and a budget with alerts.

Deletion protection is on by default and turning it off is an edit somebody has
to make on purpose. Everything here is applied by the provisioner job rather
than by a person's own credentials, so what built a project is answerable
afterwards.

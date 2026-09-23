# GitHub App Setup for Flux

This guide explains how to create and configure a GitHub App for Flux authentication.

## Why GitHub App?

GitHub App authentication is more secure than SSH keys or Personal Access Tokens because:
- Fine-grained repository permissions
- Tokens expire automatically
- Better audit trail
- Can be scoped to specific repositories

## Step 1: Create GitHub App

1. **Navigate to GitHub Settings**
   - Go to https://github.com/settings/apps
   - Click "New GitHub App"

2. **Configure the App**

   **GitHub App name:** `Flux SRE`

   **Homepage URL:** `https://github.com/safeops-course/sre`

   **Webhook:** Uncheck "Active" (not needed for Flux)

   **Repository permissions:**
   - Contents: **Read-only** (to read repository)
   - Metadata: **Read-only** (automatically selected)

   **Where can this GitHub App be installed?**
   - Select "Only on this account"

3. **Create the App**
   - Click "Create GitHub App"
   - Note the **App ID** (you'll need this later)

4. **Generate Private Key**
   - Scroll down to "Private keys"
   - Click "Generate a private key"
   - Download the `.pem` file
   - Save it securely (e.g., `~/.ssh/flux-github-app.pem`)

## Step 2: Install the GitHub App

1. **Install the App**
   - Go to the app's page: https://github.com/settings/apps/flux-sre
   - Click "Install App"
   - Select your account or organization

2. **Configure Repository Access**
   - Select "Only select repositories"
   - Choose the `safeops-course/sre` repository
   - Click "Install"

3. **Get Installation ID**
   - After installation, look at the URL
   - It will be: `https://github.com/settings/installations/XXXXXXXX`
   - The number is your **Installation ID**

## Step 3: Configure Terraform Variables

Create `infra/terraform/kind_cluster/terraform.tfvars` with your GitHub App credentials:

```hcl
# GitHub App Configuration
github_app_id              = "123456"                      # Your App ID
github_app_installation_id = "12345678"                    # Your Installation ID
github_app_private_key_file = "~/.ssh/flux-github-app.pem" # Path to downloaded PEM file

# GitOps Configuration (already configured)
flux_git_repository_url    = "https://github.com/safeops-course/sre.git"
flux_git_repository_branch = "main"
flux_kustomization_path    = "./flux/bootstrap/flux-system"
```

**Important:** Terraform will automatically create the Kubernetes secret from these variables.

## Step 4: Apply Terraform

Now you can apply the Terraform configuration:

```bash
cd infra/terraform/kind_cluster
terraform apply
```

The FluxInstance will use the GitHub App authentication to access the repository.

## Troubleshooting

### Check if the secret is correct

```bash
kubectl -n flux-system get secret flux-system -o jsonpath='{.data.app-id}' | base64 -d
kubectl -n flux-system get secret flux-system -o jsonpath='{.data.installation-id}' | base64 -d
```

### Check Flux logs

```bash
kubectl -n flux-system logs -l app=source-controller --tail=50
```

### Check GitRepository status

```bash
kubectl -n flux-system get gitrepository
kubectl -n flux-system describe gitrepository flux-system
```

### Common Issues

**Error: "failed to checkout: authentication required"**
- Verify the App is installed on the correct repository
- Verify the Installation ID is correct
- Check that the private key matches the GitHub App

**Error: "failed to get installation token"**
- Verify the App ID is correct
- Ensure the private key is valid and not expired
- Check GitHub App permissions include "Contents: Read"

## Security Best Practices

1. **Protect the private key**
   ```bash
   chmod 600 ~/.ssh/flux-github-app.pem
   ```

2. **Do not commit the private key to Git**
   - The `.pem` file should stay local
   - The Kubernetes secret contains a copy

3. **Rotate keys periodically**
   - Generate a new private key every 90 days
   - Update the Kubernetes secret

4. **Monitor App usage**
   - Check GitHub's audit log for app activity
   - Review permissions regularly

## References

- [Flux GitHub App Authentication](https://fluxcd.io/flux/components/source/gitrepositories/#github-app-authentication)
- [GitHub Apps Documentation](https://docs.github.com/en/apps)
- [Flux Operator Sync Guide](https://fluxcd.control-plane.io/operator/flux-sync/)

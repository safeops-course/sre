# Flux Upgrade Guide

## Компоненти за обновяване

Flux се състои от три основни компонента:
1. **Flux CLI** - локален инструмент за управление
2. **Flux Operator** - оператор в Kubernetes
3. **Flux Controllers** - самите Flux контролери (source, kustomize, helm, etc.)

## 1. Обновяване на Flux CLI

```bash
# Обнови CLI с Homebrew
brew upgrade fluxcd/tap/flux

# Ако има конфликт, презапиши symlink-а
brew link --overwrite fluxcd/tap/flux

# Провери версията
flux --version
```

## 2. Обновяване на Flux Operator

### Метод А: През Terraform променливи

Редактирай `terraform.tfvars`:
```hcl
flux_operator_version = "0.31.0"  # Провери последната версия
```

Приложи:
```bash
terraform apply
```

### Метод Б: Директно редактиране на променливите

Редактирай `variables.tf` и промени default стойността:
```hcl
variable "flux_operator_version" {
  default = "0.31.0"  # Нова версия
}
```

### Проверка на налични версии

```bash
# Провери последната версия на Flux Operator
helm search repo oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator --versions | head -10

# Или виж в GitHub releases
# https://github.com/controlplaneio-fluxcd/flux-operator/releases
```

## 3. Обновяване на Flux Controllers

Flux Controllers се управляват от FluxInstance ресурса. Версията се контролира от променливата `flux_version`.

### Метод А: Автоматично обновяване (препоръчително)

Използвай версия pattern `2.x` за автоматично избиране на последната 2.x версия:
```hcl
# В terraform.tfvars
flux_version = "2.x"  # Автоматично избира последната
```

### Метод Б: Конкретна версия

```hcl
# В terraform.tfvars
flux_version = "v2.7.0"  # Конкретна версия
```

### Обновяване

Flux Operator автоматично ще обнови контролерите когато промениш FluxInstance ресурса:

```bash
# Ако използваш променливи, просто apply
terraform apply

# Или ръчно обнови FluxInstance
kubectl -n flux-system patch fluxinstance flux --type merge -p '{"spec":{"distribution":{"version":"v2.7.0"}}}'
```

## 4. Пълна процедура за обновяване

```bash
# Стъпка 1: Обнови Flux CLI
brew upgrade fluxcd/tap/flux
flux --version

# Стъпка 2: Провери текущи версии
kubectl -n flux-system get fluxinstance flux
helm list -n flux-system

# Стъпка 3: Обнови terraform.tfvars
cat > terraform.tfvars <<EOF
flux_operator_version = "0.31.0"
flux_version = "2.x"
EOF

# Стъпка 4: Приложи промените
terraform plan
terraform apply

# Стъпка 5: Провери обновяването
kubectl -n flux-system get pods -w
kubectl -n flux-system get fluxinstance flux

# Стъпка 6: Провери статус
flux check
```

## 5. Rollback при проблеми

Ако срещнеш проблеми, върни се към предишната версия:

```bash
# Редактирай terraform.tfvars с предишните версии
flux_operator_version = "0.30.0"
flux_version = "v2.6.0"

# Приложи
terraform apply
```

## 6. Мониторинг на обновяването

```bash
# Гледай pod-овете
kubectl -n flux-system get pods -w

# Проверявай logs
kubectl -n flux-system logs -l app=source-controller --tail=50 -f

# Проверявай FluxInstance статус
kubectl -n flux-system describe fluxinstance flux

# Използвай flux CLI
flux check
flux get sources all
flux get kustomizations
```

## Версионна съвместимост

| Flux Operator | Flux Version | Notes |
|--------------|--------------|-------|
| 0.30.x       | 2.6.x - 2.7.x | Stable |
| 0.31.x       | 2.7.x+ | Latest features |

## Полезни линкове

- [Flux Operator Releases](https://github.com/controlplaneio-fluxcd/flux-operator/releases)
- [Flux Releases](https://github.com/fluxcd/flux2/releases)
- [Flux Upgrade Documentation](https://fluxcd.io/flux/installation/upgrade/)

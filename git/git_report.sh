#!/usr/bin/env bash

# Función para mostrar ayuda
show_help() {
    cat << EOF
Uso: $0 [OPCIONES] <directorio>

OPCIONES:
    -h, --help     Mostrar esta ayuda
    -v, --verbose  Modo verbose (mostrar más detalles)

DESCRIPCIÓN:
    Genera un informe de todos los repositorios Git encontrados en el directorio especificado.

EJEMPLOS:
    $0 /home/usuario/proyectos
    $0 -v /home/usuario/proyectos
EOF
}

# Variables por defecto
VERBOSE=false

# Procesamiento de argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -*)
            echo "Error: Opción desconocida $1" >&2
            show_help
            exit 1
            ;;
        *)
            DIR="$1"
            shift
            ;;
    esac
done

# Validación de argumentos
if [ -z "$DIR" ]; then
    echo "Error: Debe especificar un directorio" >&2
    show_help
    exit 1
fi

if [ ! -d "$DIR" ]; then
    echo "Error: '$DIR' no es un directorio válido" >&2
    exit 1
fi

if [ ! -r "$DIR" ]; then
    echo "Error: No se tienen permisos de lectura en '$DIR'" >&2
    exit 1
fi

# Arrays para rastrear repositorios no sincronizados
declare -a UNSYNC_REPOS=()
declare -a UNSYNC_TYPES=()
declare -a UNSYNC_DETAILS=()

# Función auxiliar para verificar si un repositorio ya está en la lista
repo_already_tracked() {
    local repo_path="$1"
    for tracked_repo in "${UNSYNC_REPOS[@]}"; do
        if [ "$tracked_repo" = "$repo_path" ]; then
            return 0  # Ya está rastreado
        fi
    done
    return 1  # No está rastreado
}

# Función auxiliar para agregar repositorio no sincronizado
add_unsync_repo() {
    local repo_path="$1"
    local sync_type="$2"
    local details="$3"

    if repo_already_tracked "$repo_path"; then
        # Si ya está rastreado, actualizar con el tipo más prioritario
        for i in "${!UNSYNC_REPOS[@]}"; do
            if [ "${UNSYNC_REPOS[i]}" = "$repo_path" ]; then
                # Prioridades: local_changes > divergent > ahead/behind > no_upstream > no_remotes
                case "${UNSYNC_TYPES[i]}" in
                    "no_remotes")
                        UNSYNC_TYPES[i]="$sync_type"
                        UNSYNC_DETAILS[i]="$details"
                        ;;
                    "no_upstream")
                        if [ "$sync_type" != "no_remotes" ]; then
                            UNSYNC_TYPES[i]="$sync_type"
                            UNSYNC_DETAILS[i]="$details"
                        fi
                        ;;
                    "ahead"|"behind")
                        if [ "$sync_type" = "local_changes" ] || [ "$sync_type" = "divergent" ]; then
                            UNSYNC_TYPES[i]="$sync_type"
                            UNSYNC_DETAILS[i]="$details"
                        fi
                        ;;
                    "divergent")
                        if [ "$sync_type" = "local_changes" ]; then
                            UNSYNC_TYPES[i]="$sync_type"
                            UNSYNC_DETAILS[i]="$details"
                        fi
                        ;;
                esac
                break
            fi
        done
    else
        # Agregar nuevo repositorio
        UNSYNC_REPOS+=("$repo_path")
        UNSYNC_TYPES+=("$sync_type")
        UNSYNC_DETAILS+=("$details")
    fi
}

# Función para mostrar información de un repositorio
analyze_repo() {
    local repo_dir="$1"
    echo "📁 Repositorio: $repo_dir"

    if ! cd "$repo_dir" 2>/dev/null; then
        echo "   ❌ Error: No se puede acceder al directorio"
        return 1
    fi

    # Verificar si es un repositorio Git válido
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "   ❌ Error: No es un repositorio Git válido"
        return 1
    fi

    # Obtener remotes
    local remotes
    remotes=$(git remote -v 2>/dev/null | grep "fetch")

    if [ -n "$remotes" ]; then
        echo "   🔗 Remotes:"
        # shellcheck disable=SC2001  # indentación multilínea con sed es lo más claro aquí
        echo "$remotes" | sed 's/^/      /'

        # Verificar estado de sincronización (solo si hay conexión)
        if git ls-remote --exit-code origin >/dev/null 2>&1; then
            git fetch --all --quiet 2>/dev/null || {
                echo "   ⚠️  Advertencia: No se pudo actualizar desde remotes"
            }
        fi

        local current_branch
        current_branch=$(git branch --show-current 2>/dev/null)

        if [ -n "$current_branch" ]; then
            echo "   🌿 Rama actual: $current_branch"

            local upstream
            upstream=$(git rev-parse --abbrev-ref "$current_branch@{upstream}" 2>/dev/null)

            if [ -n "$upstream" ]; then
                local ahead behind
                ahead=$(git rev-list --count "$upstream..$current_branch" 2>/dev/null || echo "0")
                behind=$(git rev-list --count "$current_branch..$upstream" 2>/dev/null || echo "0")

                if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
                    echo "   ✅ Estado: Sincronizado"
                elif [ "$ahead" -gt 0 ] && [ "$behind" -eq 0 ]; then
                    echo "   ⬆️  Estado: $ahead commit(s) adelante"
                    add_unsync_repo "$repo_dir" "ahead" "$ahead commit(s) adelante"
                elif [ "$ahead" -eq 0 ] && [ "$behind" -gt 0 ]; then
                    echo "   ⬇️  Estado: $behind commit(s) atrás"
                    add_unsync_repo "$repo_dir" "behind" "$behind commit(s) atrás"
                else
                    echo "   🔀 Estado: Divergente ($ahead adelante, $behind atrás)"
                    add_unsync_repo "$repo_dir" "divergent" "Divergente ($ahead adelante, $behind atrás)"
                fi
            else
                echo "   ❓ Estado: Sin upstream configurado"
                add_unsync_repo "$repo_dir" "no_upstream" "Sin upstream configurado"
            fi
        else
            echo "   ⚠️  Sin rama actual (HEAD desclonectado)"
        fi

        # Verificar cambios locales (siempre, no solo en modo verbose)
        local status
        status=$(git status --porcelain 2>/dev/null)
        if [ -n "$status" ]; then
            local modified staged untracked
            modified=$(echo "$status" | grep -c "^ M")
            staged=$(echo "$status" | grep -c "^M")
            untracked=$(echo "$status" | grep -c "^??")
            echo "   📝 Cambios locales: $staged staged, $modified modificados, $untracked sin seguimiento"

            # Agregar a repositorios no sincronizados si hay cambios
            if [ "$staged" -gt 0 ] || [ "$modified" -gt 0 ]; then
                add_unsync_repo "$repo_dir" "local_changes" "Cambios locales ($staged staged, $modified modificados, $untracked sin seguimiento)"
            fi
        else
            echo "   ✨ Directorio de trabajo limpio"
        fi

        # Información adicional en modo verbose
        if [ "$VERBOSE" = true ]; then
            local last_commit
            last_commit=$(git log -1 --format="%h - %s (%cr)" 2>/dev/null)
            if [ -n "$last_commit" ]; then
                echo "   📅 Último commit: $last_commit"
            fi
        fi
    else
        echo "   ❌ Sin remotes configurados (repositorio local)"
        add_unsync_repo "$repo_dir" "no_remotes" "Sin remotes configurados"
    fi
}

# Función para sincronizar un repositorio
sync_repo() {
    local repo_dir="$1"
    local sync_type="$2"

    echo "🔄 Sincronizando repositorio: $repo_dir"

    if ! cd "$repo_dir" 2>/dev/null; then
        echo "   ❌ Error: No se puede acceder al directorio"
        return 1
    fi

    case "$sync_type" in
        "ahead")
            echo "   ⬆️  Enviando cambios al remoto..."
            if git push 2>/dev/null; then
                echo "   ✅ Push completado exitosamente"
                return 0
            else
                echo "   ❌ Error al hacer push"
                return 1
            fi
            ;;
        "behind")
            echo "   ⬇️  Descargando cambios del remoto..."
            if git pull 2>/dev/null; then
                echo "   ✅ Pull completado exitosamente"
                return 0
            else
                echo "   ❌ Error al hacer pull"
                return 1
            fi
            ;;
        "local_changes")
            echo "   💾 Procesando cambios locales..."

            # Verificar si hay cambios staged
            local staged_count
            staged_count=$(git diff --cached --name-only | wc -l)

            if [ "$staged_count" -gt 0 ]; then
                echo "   📦 Creando commit con cambios staged..."
                echo "   💬 Ingrese mensaje de commit (o presione Enter para mensaje automático):"
                read -r commit_message

                if [ -z "$commit_message" ]; then
                    commit_message="Auto-commit: cambios locales sincronizados el $(date '+%Y-%m-%d %H:%M:%S')"
                fi

                if git commit -m "$commit_message" 2>/dev/null; then
                    echo "   ✅ Commit creado exitosamente"

                    # Intentar push si hay remote configurado
                    if git remote get-url origin >/dev/null 2>&1; then
                        echo "   ⬆️  Enviando commit al remoto..."
                        if git push 2>/dev/null; then
                            echo "   ✅ Push completado exitosamente"
                            return 0
                        else
                            echo "   ⚠️  Commit local creado, pero falló el push"
                            return 1
                        fi
                    else
                        echo "   ✅ Commit local creado (sin remote para push)"
                        return 0
                    fi
                else
                    echo "   ❌ Error al crear commit"
                    return 1
                fi
            else
                # Solo hay cambios modificados, preguntar si hacer add y commit
                echo "   📝 Hay cambios modificados sin stagear"
                echo "   ¿Desea agregar todos los cambios y hacer commit? (s/n)"
                read -r add_response

                if [[ "$add_response" =~ ^[Ss]$ ]]; then
                    git add -A
                    echo "   💬 Ingrese mensaje de commit (o presione Enter para mensaje automático):"
                    read -r commit_message

                    if [ -z "$commit_message" ]; then
                        commit_message="Auto-commit: cambios locales sincronizados el $(date '+%Y-%m-%d %H:%M:%S')"
                    fi

                    if git commit -m "$commit_message" 2>/dev/null; then
                        echo "   ✅ Commit creado exitosamente"

                        # Intentar push si hay remote configurado
                        if git remote get-url origin >/dev/null 2>&1; then
                            echo "   ⬆️  Enviando commit al remoto..."
                            if git push 2>/dev/null; then
                                echo "   ✅ Push completado exitosamente"
                                return 0
                            else
                                echo "   ⚠️  Commit local creado, pero falló el push"
                                return 1
                            fi
                        else
                            echo "   ✅ Commit local creado (sin remote para push)"
                            return 0
                        fi
                    else
                        echo "   ❌ Error al crear commit"
                        return 1
                    fi
                else
                    echo "   ⏭️  Omitiendo cambios locales"
                    return 1
                fi
            fi
            ;;
        "divergent")
            echo "   🔀 Repositorio divergente - requiere intervención manual"
            echo "   💡 Sugerencia: usar 'git pull --rebase' o resolver conflictos manualmente"
            return 1
            ;;
        "no_upstream")
            echo "   ❓ Sin upstream configurado - requiere configuración manual"
            echo "   💡 Sugerencia: usar 'git push -u origin <rama>' para configurar upstream"
            return 1
            ;;
        "no_remotes")
            echo "   ❌ Sin remotes configurados - repositorio local únicamente"
            echo "   💡 Sugerencia: agregar remote con 'git remote add origin <url>'"
            return 1
            ;;
        *)
            echo "   ❌ Tipo de sincronización desconocido"
            return 1
            ;;
    esac
}

# Función para mostrar desglose de repositorios no sincronizados
show_unsync_summary() {
    local unsync_count=${#UNSYNC_REPOS[@]}

    if [ "$unsync_count" -eq 0 ]; then
        echo "🎉 Todos los repositorios están sincronizados"
        return 0
    fi

    echo "=== REPOSITORIOS NO SINCRONIZADOS ==="
    echo "Total de repositorios no sincronizados: $unsync_count"
    echo

    for i in "${!UNSYNC_REPOS[@]}"; do
        echo "$((i+1)). ${UNSYNC_REPOS[i]}"
        echo "   Estado: ${UNSYNC_DETAILS[i]}"
        echo
    done

    # Preguntar si desea sincronizar
    echo "¿Desea intentar sincronizar los repositorios compatibles? (s/n)"
    read -r response

    if [[ "$response" =~ ^[Ss]$ ]]; then
        echo
        echo "=== SINCRONIZANDO REPOSITORIOS ==="

        local synced=0
        local failed=0

        for i in "${!UNSYNC_REPOS[@]}"; do
            local repo="${UNSYNC_REPOS[i]}"
            local type="${UNSYNC_TYPES[i]}"

            echo
            if sync_repo "$repo" "$type"; then
                ((synced++))
            else
                ((failed++))
            fi
        done

        echo
        echo "=== RESUMEN DE SINCRONIZACIÓN ==="
        echo "Repositorios sincronizados exitosamente: $synced"
        echo "Repositorios que requieren intervención manual: $failed"
    fi
}

# Función principal
main() {

    # Convertir DIR a ruta absoluta
    DIR=$(cd "$DIR" && pwd)

    echo "=== INFORME DE REPOSITORIOS GIT ==="
    echo "Directorio base: $DIR"
    echo "Fecha: $(date '+%Y-%m-%d %H:%M:%S')"
    echo



    local repo_count=0

    # Buscar repositorios Git de forma recursiva
    while IFS= read -r -d '' git_dir; do

        if [ -d "$git_dir" ]; then
            repo_dir=$(dirname "$git_dir")
            analyze_repo "$repo_dir"
            echo
            ((repo_count++))
        fi
    done < <(find "$DIR" -type d -name ".git" -print0 2>/dev/null)

    if [ "$repo_count" -eq 0 ]; then
        echo "❌ No se encontraron repositorios Git en el directorio especificado."
    else
        echo "=== FIN DEL INFORME ==="
        echo "Total de repositorios encontrados: $repo_count"
        echo

        # Mostrar desglose de repositorios no sincronizados
        show_unsync_summary
    fi
}

# Ejecutar función principal
main

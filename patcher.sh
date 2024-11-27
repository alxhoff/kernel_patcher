#!/bin/bash

# Temporary files for dialog
CHOICE_FILE=$(mktemp)
INPUT_FILE=$(mktemp)

# Cleanup function
cleanup() {
    rm -f "$CHOICE_FILE" "$INPUT_FILE"
}
trap cleanup EXIT

# Function: Prepare Environment
prepare_environment() {
    dialog --infobox "Cloning kernel_builder repository..." 5 50
    if ! git clone https://github.com/alxhoff/kernel_builder .builder; then
        dialog --msgbox "Failed to clone kernel_builder repository!" 10 50
        return
    fi

    cd .builder || exit
    COMMANDS=(
        "python3 kernel_builder.py build"
        "python3 kernel_builder.py clone-kernel --kernel-source-url https://github.com/alxhoff/jetson-kernel --kernel-name jetson --git-tag sensing_world_v1"
        "python3 kernel_builder.py clone-toolchain --toolchain-url https://github.com/alxhoff/Jetson-Linux-Toolchain --toolchain-name aarch64-buildroot-linux-gnu"
        "python3 kernel_builder.py clone-overlays --overlays-url https://github.com/alxhoff/jetson-kernel-overlays --kernel-name jetson --git-tag sensing_world_v1"
        "python3 kernel_builder.py clone-device-tree --device-tree-url https://github.com/alxhoff/jetson-device-tree-hardware --kernel-name jetson --git-tag sensing_world_v1"
    )

    for CMD in "${COMMANDS[@]}"; do
        if ! eval "$CMD"; then
            dialog --msgbox "Command failed: $CMD" 10 50
            cd ..
            return
        fi
    done

    dialog --msgbox "Environment prepared successfully!" 10 50
    cd ..
}

# Function: Patch Kernel
patch_kernel() {
    # Check if the repository is already cloned
    if [ ! -d .patches ]; then
        dialog --infobox "Cloning kernel_patches repository..." 5 50
        if ! git clone https://github.com/alxhoff/kernel_patches .patches; then
            dialog --msgbox "Failed to clone kernel_patches repository!" 10 50
            return
        fi
    fi

    cd .patches || exit

    # Fetch tags ordered by creation date
    TAGS=$(git for-each-ref --sort=creatordate --format '%(refname:short) %(subject)' refs/tags)

    # Check if tags exist
    if [ -z "$TAGS" ]; then
        dialog --msgbox "No tags found in kernel_patches repository!" 10 50
        cd ..
        return
    fi

    # Prepare menu items
    MENU_ITEMS=()
    while IFS= read -r line; do
        TAG_NAME=$(echo "$line" | awk '{print $1}')
        TAG_COMMENT=$(echo "$line" | cut -d' ' -f2-)
        MENU_ITEMS+=("$TAG_NAME" "$TAG_COMMENT")
    done <<< "$TAGS"

    # Display menu
    dialog --menu "Select a patch version to apply up to:" 20 70 15 "${MENU_ITEMS[@]}" 2>"$CHOICE_FILE"

    SELECTED_TAG=$(<"$CHOICE_FILE")

    if [ -n "$SELECTED_TAG" ]; then
        dialog --yesno "Apply patches up to $SELECTED_TAG?" 7 50
        RESPONSE=$?
        if [ $RESPONSE -eq 0 ]; then
            dialog --infobox "Applying patches sequentially up to $SELECTED_TAG..." 7 50
            for TAG in $(git tag --sort=creatordate); do
                if [[ "$TAG" > "$SELECTED_TAG" ]]; then
                    break
                fi
                git checkout "$TAG"
                PATCH_FILE="jetson.patch"
                if [ -f "$PATCH_FILE" ]; then
                    if ! patch -d ../.builder/kernels/jetson -p1 <"$PATCH_FILE"; then
                        dialog --msgbox "Failed to apply patch $PATCH_FILE from tag $TAG!" 10 50
                        cd ..
                        return
                    fi
                else
                    dialog --msgbox "Patch file $PATCH_FILE not found in tag $TAG!" 10 50
                    cd ..
                    return
                fi
            done

            # Set localversion for compilation
            echo "$SELECTED_TAG" > ../.localversion
            dialog --msgbox "Patches applied. Local version set to $SELECTED_TAG." 7 50
        else
            dialog --msgbox "Patch application cancelled." 7 50
        fi
    else
        dialog --msgbox "No patch version selected." 7 50
    fi

    cd ..
}

# Function: Compile Kernel
compile_kernel() {
    if [ ! -f .localversion ]; then
        dialog --msgbox "Local version not set. Please run 'Patch Kernel' first." 10 50
        return
    fi

    LOCALVERSION=$(<.localversion)

    cd .builder || exit

    # Step 1: Compile the kernel
    dialog --infobox "Compiling kernel with local version $LOCALVERSION..." 5 50
    if ! python3 kernel_builder.py compile --kernel-name jetson --arch arm64 --toolchain-name aarch64-buildroot-linux-gnu --config tegra_defconfig --localversion "$LOCALVERSION"; then
        dialog --msgbox "Kernel compilation failed!" 10 50
        cd ..
        return
    fi

    # Step 2: Copy Image and modules
    KERNEL_DIR=".builder/kernels/jetson/modules"
    TARGET_IMAGE="$KERNEL_DIR/boot/Image-$LOCALVERSION"
    TARGET_MODULES="$KERNEL_DIR/lib/modules/$LOCALVERSION"

    if [ -f "$TARGET_IMAGE" ] && [ -d "$TARGET_MODULES" ]; then
        cp "$TARGET_IMAGE" ../Image-"$LOCALVERSION"
        cp -r "$TARGET_MODULES" ../modules-"$LOCALVERSION"
        dialog --msgbox "Kernel image and modules copied to the root directory!" 10 50
    else
        dialog --msgbox "Failed to find Image or modules for local version $LOCALVERSION." 10 50
    fi

    cd ..
}

# Main Menu Function
main_menu() {
    while true; do
        dialog --clear --menu "Kernel Builder Tool" 15 50 6 \
            1 "Prepare Environment" \
            2 "Patch Kernel" \
            3 "Compile" \
            4 "Exit" 2>"$CHOICE_FILE"

        CHOICE=$(<"$CHOICE_FILE")
        case $CHOICE in
            1) prepare_environment ;;
            2) patch_kernel ;;
            3) compile_kernel ;;
            4) break ;;
        esac
    done
}

# Start the script
main_menu


#!/usr/bin/env python3
"""
generate_db.py

Reads the JSON output from the Dart parser and creates a Sourcetrail DB (.srctrldb) 
using the Numbat library.

Usage:
  python generate_db.py --input path/to/output.json --output path/to/result.srctrldb [--verbose]
"""

import argparse
import json
import os
import re
import sys
import logging
from pathlib import Path
from numbat import SourcetrailDB

def get_or_create_package_namespace(package_path, module_map, db, package_map):
    """
    Create or retrieve a nested namespace node for the given package_path under the appropriate module.
    If package_path matches or starts with a known module path, we nest under that module.
    Otherwise, we place it under an EXTERNAL namespace for third-party or unknown packages.
    """
    if package_path in package_map:
        return package_map[package_path]

    # Find the module that best matches this package path (longest prefix match)
    best_module = None
    best_len = 0
    for mp in module_map:
        # skip the "EXTERNAL" sentinel if present
        if mp == "EXTERNAL":
            continue
        if package_path == mp or package_path.startswith(mp + "/"):
            if len(mp) > best_len:
                best_len = len(mp)
                best_module = mp

    # If no suitable module found, place under EXTERNAL
    if best_module is None:
        best_module = "EXTERNAL"
        if "EXTERNAL" not in module_map:
            external_id = db.record_namespace(
                name="EXTERNAL",
                parent_id=None,
                is_indexed=False
            )
            module_map["EXTERNAL"] = external_id
        parent_id = module_map["EXTERNAL"]
        parts = package_path.split("/")
    else:
        parent_id = module_map[best_module]
        remainder = package_path[len(best_module):].lstrip("/")
        parts = remainder.split("/") if remainder else []

    current_parent = parent_id
    current_path = best_module

    # Create nested namespaces for each path segment
    for p in parts:
        new_path = current_path + "/" + p if current_path != "EXTERNAL" else p
        if new_path in package_map:
            current_parent = package_map[new_path]
            current_path = new_path
            continue
        else:
            ns_id = db.record_namespace(
                name=p,
                parent_id=current_parent,
                is_indexed=True,
                delimiter="/"
            )
            package_map[new_path] = ns_id
            current_parent = ns_id
            current_path = new_path

    package_map[package_path] = current_parent
    return current_parent

def main():
    parser = argparse.ArgumentParser(description="Generate a Sourcetrail DB from DartSrcCtrl JSON output using Numbat.")
    parser.add_argument("-i", "--input", required=True, help="Path to the JSON file with symbols and references.")
    parser.add_argument("-o", "--output", required=True, help="Path to the output .srctrldb file.")
    parser.add_argument("-v", "--verbose", action="store_true", help="Enable verbose output for debugging.")
    args = parser.parse_args()

    verbose = args.verbose
    input_path = Path(args.input)
    output_path = Path(args.output)

    # Set up logging
    log_level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=log_level,
        format='%(levelname)s: %(message)s'
    )
    logger = logging.getLogger("generate_db")

    # Check if output directory exists and is writable
    output_dir = output_path.parent
    if not output_dir.exists():
        logger.warning(f"Output directory does not exist: {output_dir}")
        try:
            output_dir.mkdir(parents=True, exist_ok=True)
            logger.info(f"Created output directory: {output_dir}")
        except Exception as e:
            logger.error(f"Failed to create output directory: {e}")
            exit(1)

    if not os.access(output_dir, os.W_OK):
        logger.error(f"Output directory is not writable: {output_dir}")
        exit(1)

    if not input_path.exists():
        logger.error(f"Input file does not exist: {input_path}")
        exit(1)

    if output_path.suffix.lower() != ".srctrldb":
        logger.error(f"Output file must have .srctrldb extension: {output_path}")
        exit(1)

    # Load JSON data
    try:
        with open(input_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        
        symbols = data.get("symbols", [])
        references = data.get("references", [])
        packages = data.get("packages", [])
        
        logger.info(f"Loaded {len(symbols)} symbols, {len(references)} references, and {len(packages)} packages from {input_path}")
    except Exception as e:
        logger.error(f"Failed to load JSON data: {e}")
        exit(1)

    # Open (and clear) the Sourcetrail DB
    try:
        db = SourcetrailDB.open(output_path, clear=True)
        logger.info(f"Opened Sourcetrail database at {output_path}")
    except Exception as e:
        logger.error(f"Failed to open Sourcetrail DB: {e}")
        exit(1)

    # STEP 0: Build a top-level namespace for each package in the JSON
    # The first entry in 'packages' should be the main package; mark it as indexed.
    module_map = {}
    for idx, m in enumerate(packages):
        pkg_name = m.get("name", "")
        pkg_version = m.get("version", "")
        if pkg_name:
            # Combine name & version for the node name
            full_name = pkg_name
            if pkg_version:
                full_name += f"@{pkg_version}"
            
            # The first package is presumably the main package, so is_indexed = True
            is_main = (idx == 0)
            mod_id = db.record_namespace(
                name=full_name,
                parent_id=None,
                is_indexed=is_main,
                delimiter="/"
            )
            module_map[pkg_name] = mod_id

    # STEP 1: Gather unique file paths and record them with language "dart"
    file_path_map = {}
    unique_files = set()

    # Collect files from symbols
    for sym in symbols:
        file_path = sym.get("File", "")
        if file_path:
            unique_files.add(file_path)

    # Collect files from references
    for ref in references:
        file_path = ref.get("File", "")
        if file_path:
            unique_files.add(file_path)

    for fpath in unique_files:
        abs_path = Path(fpath).resolve()
        file_id = db.record_file(abs_path)
        # For best results, set language to "dart"
        db.record_file_language(file_id, "dart")
        file_path_map[fpath] = file_id

    # A map from our Symbol.ID to the recorded Numbat symbol ID
    symbol_id_map = {}
    # We'll store package namespace IDs here
    package_map = {}

    # STEP 2: Insert all symbols.
    # Sort symbols so that the parent type (class/mixin) is recorded before methods.
    def kind_priority(k):
        priority_map = {
            "package": 0,
            "library": 1,
            "class_": 2,
            "mixin": 2,
            "extension": 2,
            "enum_": 2,
            "field": 3,
            "function": 4,
            "method": 4,
            "constructor": 4,
            "variable": 5,
            "parameter": 6,
        }
        return priority_map.get(k, 7)

    symbols.sort(key=lambda s: kind_priority(s["Kind"]))

    for sym in symbols:
        sym_id = sym["ID"]
        sym_name = sym["Name"]
        sym_kind = sym["Kind"]
        package_path = sym.get("PackagePath", "")
        hover_display = sym.get("Sig", "")
        indexed = not sym.get("External", False)

        # Identify (or create) the package namespace that owns this symbol
        pkg_parent_id = None
        if package_path:
            pkg_parent_id = get_or_create_package_namespace(package_path, module_map, db, package_map)

        # If the parser assigned a ParentID, we try that first.
        parent_id = pkg_parent_id
        stored_parent_id = sym.get("ParentID", 0)
        if stored_parent_id != 0:
            mapped_parent_id = symbol_id_map.get(stored_parent_id)
            if mapped_parent_id is not None:
                parent_id = mapped_parent_id

        # Decide how to record the symbol based on sym_kind
        if sym_kind == "library":
            # The library itself maps to the namespace
            recorded_id = pkg_parent_id
        elif sym_kind == "class_":
            recorded_id = db.record_class(
                name=sym_name,
                parent_id=parent_id,
                is_indexed=indexed
            )
        elif sym_kind == "mixin":
            # Mixins are similar to interfaces in Sourcetrail
            recorded_id = db.record_interface(
                name=sym_name,
                parent_id=parent_id,
                is_indexed=indexed
            )
        elif sym_kind == "extension":
            # Extensions are recorded as namespaces
            recorded_id = db.record_namespace(
                name=sym_name,
                parent_id=parent_id,
                is_indexed=indexed
            )
        elif sym_kind == "enum_":
            # Enums are recorded as classes
            recorded_id = db.record_class(
                name=sym_name,
                parent_id=parent_id,
                is_indexed=indexed
            )
        elif sym_kind == "field":
            recorded_id = db.record_field(
                name=sym_name,
                parent_id=parent_id,
                is_indexed=indexed
            )
        elif sym_kind == "function":
            recorded_id = db.record_function(
                name=sym_name,
                parent_id=parent_id,
                is_indexed=indexed
            )
        elif sym_kind == "method":
            recorded_id = db.record_method(
                name=sym_name,
                parent_id=parent_id,
                is_indexed=indexed
            )
        elif sym_kind == "constructor":
            recorded_id = db.record_method(
                name=sym_name,
                parent_id=parent_id,
                is_indexed=indexed
            )
        elif sym_kind == "variable":
            # Use global_variable instead of variable
            recorded_id = db.record_global_variable(
                name=sym_name,
                parent_id=parent_id,
                is_indexed=indexed
            )
        else:
            # Default to namespace for unknown types
            recorded_id = db.record_namespace(
                name=sym_name,
                parent_id=parent_id,
                is_indexed=indexed
            )

        # Store the mapping from our ID to Numbat's ID
        symbol_id_map[sym_id] = recorded_id

        # Record the symbol location in the file
        file_path = sym.get("File", "")
        if file_path and file_path in file_path_map:
            file_id = file_path_map[file_path]
            line = sym.get("Line", 0)
            if line > 0:  # Sourcetrail uses 1-based line numbers
                # Calculate end column based on symbol name length
                name_length = len(sym_name) if sym_name else 1
                
                try:
                    db.record_symbol_location(
                        symbol_id=recorded_id,
                        file_id=file_id,
                        start_line=line,
                        start_column=sym.get("Column", 0),
                        end_line=line,
                        end_column=sym.get("Column", 0) + name_length
                    )
                except Exception as e:
                    logger.warning(f"Failed to record symbol location for {sym_name}: {e}")

        # Add signature/hover text if available
        if hover_display:
            try:
                # Try to record signature if method exists
                if hasattr(db, 'record_symbol_signature'):
                    db.record_symbol_signature(
                        symbol_id=recorded_id,
                        signature=hover_display
                    )
                else:
                    logger.debug(f"Skipping signature for {sym_name}: record_symbol_signature method not available")
            except Exception as e:
                logger.warning(f"Failed to record symbol signature for {sym_name}: {e}")

    # STEP 3: Insert all references
    for ref in references:
        from_id = ref.get("FromID", 0)
        to_id = ref.get("ToID", 0)
        ref_type = ref.get("RefType", "")
        
        # Skip if we don't have valid IDs
        if from_id == 0 or to_id == 0:
            continue
            
        # Map our IDs to Numbat IDs
        from_numbat_id = symbol_id_map.get(from_id)
        to_numbat_id = symbol_id_map.get(to_id)
        
        if from_numbat_id is None or to_numbat_id is None:
            continue
            
        # We don't need to determine edge_type anymore since we're using specific methods
        # for each reference type directly in the code below
            
        # Record the reference based on its type
        file_id = file_path_map.get(ref.get("File", ""), 0)
        line = ref.get("Line", 0)
        column = ref.get("Column", 0)
        
        try:
            # Use the appropriate reference recording method based on reference type
            if ref_type == "call":
                db.record_ref_call(
                    source_id=from_numbat_id,
                    dest_id=to_numbat_id
                )
            elif ref_type == "extends_" or ref_type == "implements_" or ref_type == "with_":
                db.record_ref_inheritance(
                    source_id=from_numbat_id,
                    dest_id=to_numbat_id
                )
            elif ref_type == "override":
                db.record_ref_override(
                    source_id=from_numbat_id,
                    dest_id=to_numbat_id
                )
            elif ref_type == "import":
                db.record_ref_include(
                    source_id=from_numbat_id,
                    dest_id=to_numbat_id
                )
            else:
                # Default to usage for other reference types
                db.record_ref_usage(
                    source_id=from_numbat_id,
                    dest_id=to_numbat_id
                )
        except Exception as e:
            logger.warning(f"Failed to record reference from {from_id} to {to_id}: {e}")
        
    try:
        # Commit and close the database
        db.commit()
        logger.info(f"Successfully committed changes to the database")
        db.close()
        logger.info(f"Successfully created Sourcetrail database at: {output_path}")
        logger.info(f"Processed {len(symbols)} symbols and {len(references)} references")
        return True
    except Exception as e:
        logger.error(f"Failed to commit or close the database: {e}")
        return False

if __name__ == "__main__":
    main()

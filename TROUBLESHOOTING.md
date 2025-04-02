# Troubleshooting Sourcetrail Database Generation

This document provides information about the fixes made to the Sourcetrail database generation component of DartSrcCtrl.

## API Compatibility Issues Fixed

The following API compatibility issues with the Numbat library were fixed:

1. **Symbol Location Recording**
   - Updated parameter names in `record_symbol_location` to use `start_line`, `start_column`, `end_line`, and `end_column`
   - Added proper error handling for symbol location recording

2. **Symbol Type Recording**
   - Replaced `record_variable` with `record_global_variable` for variable symbols
   - Added conditional check for `record_symbol_signature` method

3. **Reference Recording**
   - Replaced generic `record_reference` with specialized methods:
     - `record_ref_call` for function/method calls
     - `record_ref_inheritance` for class inheritance relationships
     - `record_ref_override` for method overrides
     - `record_ref_include` for imports
     - `record_ref_usage` for general symbol usage
   - Updated parameter names to match the Numbat API (using `source_id` and `dest_id`)
   - Removed non-existent edge type constants

## Error Handling Improvements

1. **Logging System**
   - Added proper Python logging setup
   - Added verbose output option for detailed debugging information
   - Replaced print statements with structured logging

2. **Exception Handling**
   - Added try-except blocks around critical operations
   - Added graceful fallbacks for missing API methods
   - Improved error reporting with specific error messages

## Usage Tips

- Use the `--verbose` flag when running DartSrcCtrl to get detailed information about the database generation process
- Check the generated JSON file (use `--keepjson` flag) if you encounter issues with the database generation
- Make sure you have Numbat version 0.2.2 or later installed

## Known Limitations

While the database generation now works correctly with the Numbat API, some visualization aspects in Sourcetrail may still require further refinement depending on your specific use case.

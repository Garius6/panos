#+build !js
package core

import "core:os"

resolve_existing_import_path :: proc(import_spec: string, importer_dir: string) -> (string, bool) {
	local_path := resolve_import_path(import_spec, importer_dir)
	if os.exists(local_path) {
		return local_path, true
	}
	local_dir_index := resolve_import_dir_index_path(import_spec, importer_dir)
	if os.exists(local_dir_index) {
		return local_dir_index, true
	}

	modules_path := resolve_import_path(import_spec, "модули")
	if os.exists(modules_path) {
		return modules_path, true
	}
	modules_dir_index := resolve_import_dir_index_path(import_spec, "модули")
	if os.exists(modules_dir_index) {
		return modules_dir_index, true
	}

	if env_dir, found := os.lookup_env("PANOS_STDLIB", context.allocator); found {
		stdlib_path := resolve_import_path(import_spec, env_dir)
		if os.exists(stdlib_path) {
			return stdlib_path, true
		}
		stdlib_dir_index := resolve_import_dir_index_path(import_spec, env_dir)
		if os.exists(stdlib_dir_index) {
			return stdlib_dir_index, true
		}
	}

	stdlib_path := resolve_import_path(import_spec, "std")
	if os.exists(stdlib_path) {
		return stdlib_path, true
	}
	stdlib_dir_index := resolve_import_dir_index_path(import_spec, "std")
	if os.exists(stdlib_dir_index) {
		return stdlib_dir_index, true
	}

	return local_path, false
}

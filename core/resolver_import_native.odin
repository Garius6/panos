#+build !js
package core

import "core:os"

resolve_existing_import_path :: proc(import_spec: string, importer_dir: string) -> (string, bool) {
	local_path := resolve_import_path(import_spec, importer_dir)
	if os.exists(local_path) {
		return local_path, true
	}

	// if is_bare_import_spec(import_spec) {
	modules_path := resolve_import_path(import_spec, "модули")
	if os.exists(modules_path) {
		return modules_path, true
	}

	if env_dir, found := os.lookup_env("PANOS_STDLIB", context.allocator); found {
		stdlib_path := resolve_import_path(import_spec, env_dir)
		if os.exists(stdlib_path) {
			return stdlib_path, true
		}
	}

	stdlib_path := resolve_import_path(import_spec, "std")
	if os.exists(stdlib_path) {
		return stdlib_path, true
	}
	// }

	return local_path, false
}

package com.filetoolkit

import androidx.core.content.FileProvider

/**
 * The manifest merger merges <provider> entries by android:name, so declaring the
 * stock androidx FileProvider would collide with the host app's (or another
 * library's) own FileProvider. A dedicated subclass keeps ours separate.
 */
class FileToolkitFileProvider : FileProvider()

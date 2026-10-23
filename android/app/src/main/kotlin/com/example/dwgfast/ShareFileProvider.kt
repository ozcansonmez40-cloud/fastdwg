package com.example.dwgfast

import androidx.core.content.FileProvider

/// Dedicated FileProvider subclass for outgoing drawing shares. share_plus
/// already registers the base FileProvider class under its own authority, so
/// a distinct subclass is required to declare a second provider entry.
class ShareFileProvider : FileProvider()

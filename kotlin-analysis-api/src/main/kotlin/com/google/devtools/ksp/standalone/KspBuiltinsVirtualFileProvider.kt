package com.google.devtools.ksp.standalone

import org.jetbrains.kotlin.analysis.decompiler.psi.BuiltinsVirtualFileProvider
import org.jetbrains.kotlin.analysis.decompiler.psi.BuiltinsVirtualFileProviderCliImpl
import org.jetbrains.kotlin.com.intellij.openapi.module.Module
import org.jetbrains.kotlin.com.intellij.openapi.project.Project
import org.jetbrains.kotlin.com.intellij.openapi.vfs.StandardFileSystems
import org.jetbrains.kotlin.com.intellij.openapi.vfs.VirtualFile
import org.jetbrains.kotlin.com.intellij.openapi.vfs.VirtualFileManager
import org.jetbrains.kotlin.com.intellij.psi.search.DelegatingGlobalSearchScope
import org.jetbrains.kotlin.com.intellij.psi.search.GlobalSearchScope
import org.jetbrains.kotlin.name.StandardClassIds
import org.jetbrains.kotlin.serialization.deserialization.builtins.BuiltInSerializerProtocol

/**
 * Finds `.kotlin_builtins` in the stdlib jar on the libraries. The stock provider collects
 * class-loader resource URLs into a set; under Native Image those are `resource://app/…` URLs, and
 * `URL.hashCode` resolves their host.
 */
class KspBuiltinsVirtualFileProvider : BuiltinsVirtualFileProvider() {
  private val files: Set<VirtualFile> by lazy {
    val jar = stdlib ?: return@lazy BuiltinsVirtualFileProviderCliImpl().getBuiltinVirtualFiles()
    val fs = VirtualFileManager.getInstance().getFileSystem(StandardFileSystems.JAR_PROTOCOL)
    StandardClassIds.builtInsPackages.mapNotNullTo(LinkedHashSet()) {
      fs.findFileByPath("$jar!/${BuiltInSerializerProtocol.getBuiltInsFilePath(it)}")
    }
  }

  override fun getBuiltinVirtualFiles(): Set<VirtualFile> = files

  override fun createBuiltinsScope(project: Project): GlobalSearchScope =
    object : DelegatingGlobalSearchScope(GlobalSearchScope.filesScope(project, files)) {
      override fun isSearchInModuleContent(aModule: Module) = false

      override fun isSearchInLibraries() = true
    }

  companion object {
    /** Absolute path of the stdlib jar, set before the session is created. */
    @Volatile var stdlib: String? = null
  }
}

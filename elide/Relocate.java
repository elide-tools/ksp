import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import org.objectweb.asm.*;
import org.objectweb.asm.commons.*;

/**
 * Usage: Relocate <out.jar> <in.jar>...
 * Relocate the packages kotlin-compiler-embeddable relocates, so classes bind to its copies. The first
 * input wins for duplicate entries.
 */
public class Relocate {
  // Fixed entry time (2010-01-01) so the output is reproducible.
  static final long FIXED_TIME = 1262304000000L;

  static final String[] PREFIXES = {
    "com/intellij/", "com/google/common/", "it/unimi/", "kotlinx/collections/immutable/", "net/jpountz/",
    "one/util/", "org/antlr/", "org/apache/log4j/", "com/fasterxml/aalto/", "org/codehaus/stax2/",
    "org/fusesource/", "org/jdom/", "org/jline/", "org/picocontainer/",
  };

  static String map(String name) {
    for (String p : PREFIXES) if (name.startsWith(p)) return "org/jetbrains/kotlin/" + name;
    return name;
  }

  /** Relocate a class name inside metadata text (`com/intellij/A`, `Lcom/intellij/A;`, or dotted). */
  static String mapText(String s) {
    for (String p : PREFIXES) {
      String dotted = p.replace('/', '.');
      if (s.startsWith(p)) return "org/jetbrains/kotlin/" + s;
      if (s.startsWith("L" + p)) return "Lorg/jetbrains/kotlin/" + s.substring(1);
      if (s.startsWith(dotted)) return "org.jetbrains.kotlin." + s;
    }
    return s;
  }

  public static void main(String[] args) throws Exception {
    Remapper remapper = new Remapper() {
      @Override public String map(String internalName) { return Relocate.map(internalName); }
    };
    try (ZipOutputStream out = new ZipOutputStream(new FileOutputStream(args[0]))) {
      Set<String> seen = new HashSet<>();
      for (int i = 1; i < args.length; i++) {
        try (ZipFile zf = new ZipFile(args[i])) {
          for (var e : Collections.list(zf.entries())) {
            if (e.isDirectory()) continue;
            byte[] b = zf.getInputStream(e).readAllBytes();
            String name = e.getName();
            if (name.endsWith(".class")) {
              ClassReader r = new ClassReader(b);
              ClassWriter w = new ClassWriter(0);
              r.accept(new ClassRemapper(w, remapper) {
                @Override public AnnotationVisitor visitAnnotation(String desc, boolean visible) {
                  AnnotationVisitor av = super.visitAnnotation(desc, visible);
                  if (!"Lkotlin/Metadata;".equals(desc)) return av;
                  // Kotlin metadata names classes in its d2 string table; relocate those too.
                  return new AnnotationVisitor(Opcodes.ASM9, av) {
                    @Override public AnnotationVisitor visitArray(String name) {
                      AnnotationVisitor inner = super.visitArray(name);
                      if (!"d2".equals(name)) return inner;
                      return new AnnotationVisitor(Opcodes.ASM9, inner) {
                        @Override public void visit(String n, Object value) {
                          super.visit(n, value instanceof String str ? mapText(str) : value);
                        }
                      };
                    }
                  };
                }
              }, 0);
              b = w.toByteArray();
              name = map(name.substring(0, name.length() - 6)) + ".class";
            } else if (name.startsWith("META-INF/services/")) {
              String svc = name.substring("META-INF/services/".length());
              name = "META-INF/services/" + map(svc.replace('.', '/')).replace('/', '.');
              String text = new String(b);
              StringBuilder sb = new StringBuilder();
              for (String line : text.split("\n")) sb.append(map(line.trim().replace('.', '/')).replace('/', '.')).append('\n');
              b = sb.toString().getBytes();
            }
            if (name.startsWith("META-INF/") && name.endsWith(".xml")) {
              // Class-name attributes in plugin descriptors; extension-point namespaces stay as-is.
              b = new String(b).replaceAll(
                  "((?:implementationClass|interface|implementation|serviceInterface|serviceImplementation|beanClass|testServiceImplementation|headlessImplementation)=\\\")com\\.intellij\\.",
                  "$1org.jetbrains.kotlin.com.intellij.").getBytes();
            }
            if (!seen.add(name)) continue;
            ZipEntry entry = new ZipEntry(name);
            entry.setTime(FIXED_TIME);
            out.putNextEntry(entry);
            out.write(b);
            out.closeEntry();
          }
        }
      }
    }
  }
}

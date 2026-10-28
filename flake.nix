{
  description = "Metals language server and standalone MCP server";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      inherit (pkgs) lib;
      jdk = pkgs.jdk21;
      source = self;
      buildDefinition = lib.cleanSourceWith {
        src = source;
        filter =
          path: type:
          let
            relative = lib.removePrefix "${source}/" (toString path);
          in
          relative == "build.sbt"
          || relative == ".jvmopts"
          || relative == "project"
          || (
            lib.hasPrefix "project/" relative
            && (
              type == "directory"
              || lib.hasSuffix ".scala" relative
              || lib.hasSuffix ".sbt" relative
              || lib.hasSuffix ".properties" relative
            )
          );
      };
      javaOptions = lib.escapeShellArgs [
        "-XX:+UseG1GC"
        "-XX:+UseStringDeduplication"
        "-Xss4m"
        "-Xms100m"
        "-Djol.magicFieldOffset=true"
        "-Djol.tryWithSudo=true"
        "-Djdk.attach.allowAttachSelf"
        "--add-opens=java.base/java.nio=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.code=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.comp=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.jvm=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.main=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.model=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.processing=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.resources=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED"
        "--add-exports=jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED"
        "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED"
        "--add-opens=jdk.compiler/com.sun.tools.javac.code=ALL-UNNAMED"
        "--add-opens=jdk.compiler/com.sun.tools.javac.comp=ALL-UNNAMED"
        "--add-opens=jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED"
        "--add-opens=jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED"
        "-XX:+DisplayVMOutputToStderr"
        "-Xlog:disable"
        "-Xlog:all=warning,gc=warning:stderr"
      ];

      sbtDependencies = pkgs.stdenvNoCC.mkDerivation {
        pname = "metals-sbt-dependencies";
        version = "2.0.0";
        src = buildDefinition;
        nativeBuildInputs = [
          pkgs.sbt
          jdk
          pkgs.cacert
        ];
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = "sha256-2NYIvcjS3/Iz9LCF92F9peaMoaFaKYgbAAnNu9jTl8s=";

        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME" "$out"
          export JAVA_HOME=${jdk}
          export COURSIER_CACHE="$out/coursier"
          sbt -batch \
            -Dsbt.boot.directory="$out/sbt-boot" \
            -Dsbt.ivy.home="$out/ivy2" \
            "metals-mcp/Compile/update" \
            "metals/Compile/update" \
            "mtags/Compile/update" \
            "mtags-java/Compile/update" \
            "mtags-protobuf/Compile/update" \
            "mtagsShared/Compile/update" \
            "interfaces/Compile/update" \
            "jsemanticdb/Compile/update" \
            "semanticdb-javac/Compile/update" \
            "semanticdb-protoc/Compile/update" \
            "turbine/Compile/update" \
            "metals/scalaCompilerBridgeBinaryJar" \
            "jsemanticdb/protocExecutable"
          runHook postBuild
        '';

        installPhase = "true";
      };

      metals = pkgs.stdenvNoCC.mkDerivation {
        pname = "metals";
        version = "2.0.0";
        src = source;
        nativeBuildInputs = [
          pkgs.sbt
          jdk
          pkgs.makeWrapper
        ];
        buildInputs = [ sbtDependencies ];

        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          cp -r ${sbtDependencies}/sbt-boot "$HOME/sbt-boot"
          cp -r ${sbtDependencies}/coursier "$HOME/coursier"
          if [ -d ${sbtDependencies}/ivy2 ]; then
            cp -r ${sbtDependencies}/ivy2 "$HOME/ivy2"
          fi
          chmod -R u+w "$HOME"
          export JAVA_HOME=${jdk}
          export COURSIER_CACHE="$HOME/coursier"

          if ! sbt -batch \
            -Dsbt.boot.directory="$HOME/sbt-boot" \
            -Dsbt.ivy.home="$HOME/ivy2" \
            "metals-mcp/Compile/packageBin" \
            "show metals-mcp/Runtime/fullClasspath" > "$TMPDIR/sbt-output.log" 2>&1; then
            cat "$TMPDIR/sbt-output.log" >&2
            exit 1
          fi

          sed -nE 's/^\[info\] \* Attributed\((.*)\)$/\1/p' \
            "$TMPDIR/sbt-output.log" > "$TMPDIR/classpath-entries"
          if [ ! -s "$TMPDIR/classpath-entries" ]; then
            cat "$TMPDIR/sbt-output.log" >&2
            echo "Could not extract metals-mcp runtime classpath from sbt output" >&2
            exit 1
          fi
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p "$out/bin" "$out/lib"

          classpath=""
          index=0
          while IFS= read -r entry; do
            test -e "$entry"
            destination="$out/lib/$index"
            cp -rL "$entry" "$destination"
            if [ -n "$classpath" ]; then
              classpath="$classpath:$destination"
            else
              classpath="$destination"
            fi
            index=$((index + 1))
          done < "$TMPDIR/classpath-entries"

          makeWrapper ${jdk}/bin/java "$out/bin/metals" \
            --set JAVA_HOME ${jdk} \
            --add-flags "${javaOptions} -cp $classpath scala.meta.metals.Main"
          makeWrapper ${jdk}/bin/java "$out/bin/metals-mcp" \
            --set JAVA_HOME ${jdk} \
            --add-flags "${javaOptions} -cp $classpath scala.meta.metals.McpMain"
          runHook postInstall
        '';

        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck
          "$out/bin/metals" --version | grep -q "2.0.0"
          "$out/bin/metals-mcp" --version | grep -q "2.0.0"
          runHook postInstallCheck
        '';

        meta = {
          description = "Metals language server and standalone MCP server";
          homepage = "https://scalameta.org/metals/";
          license = lib.licenses.asl20;
          mainProgram = "metals";
          platforms = [ system ];
        };
      };
    in
    {
      packages.${system} = {
        inherit metals;
        default = metals;
      };
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [
          jdk
          pkgs.sbt
        ];
      };
    };
}

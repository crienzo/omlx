class Omlx < Formula
  desc "LLM inference server optimized for Apple Silicon"
  homepage "https://github.com/jundot/omlx"
  url "https://github.com/jundot/omlx/archive/refs/tags/v0.3.8.tar.gz"
  sha256 "4a18e2cf9be2313415705ef57584ed9fa38c91ab7804410008e420756cce557d"
  license "Apache-2.0"

  head "https://github.com/jundot/omlx.git", branch: "main"

  option "with-grammar", "Install xgrammar for structured output (requires torch, ~2GB)"

  depends_on "rust" => :build
  depends_on "python@3.11"
  depends_on :macos
  depends_on arch: :arm64

  # mlx-audio pins mlx-lm==0.31.1 which conflicts with omlx's git-pinned
  # mlx-lm. Fetch source separately so we can patch the pin before install.
  resource "mlx-audio" do
    url "https://github.com/Blaizzy/mlx-audio.git",
      revision: "51753266e0a4f766fd5e6fbc46652224efc23981"
  end

  service do
    run [opt_bin/"omlx", "serve"]
    keep_alive true
    working_dir var
    log_path var/"log/omlx.log"
    error_log_path var/"log/omlx.log"
    environment_variables PATH: std_service_path_env
  end

  def install
    # Create venv with pip so dependency resolution works properly
    system "python3.11", "-m", "venv", libexec

    # Build Rust-based packages from source with headerpad to prevent
    # Homebrew dylib ID fixup failure (Mach-O header too small for absolute paths).
    # tokenizers is excluded: its wheel ships a stable-ABI .abi3.so that does
    # not need Homebrew's dylib ID rewrite, and building from source fails on
    # macOS 15+ due to PyO3 linker errors (missing Python symbols at link time).
    ENV.append "LDFLAGS", "-Wl,-headerpad_max_install_names"

    # Install omlx (with optional grammar extra for structured output)
    install_spec = build.with?("grammar") ? "#{buildpath}[grammar]" : buildpath.to_s
    system libexec/"bin/pip", "install", "--no-binary", "pydantic-core,rpds-py,tiktoken", install_spec

    # Install mlx-audio with patched mlx-lm pin to avoid version conflict
    resource("mlx-audio").stage do
      inreplace "pyproject.toml", '"mlx-lm==0.31.1"', '"mlx-lm>=0.31.1"'
      system libexec/"bin/pip", "install", ".[all]"
    end

    # python-multipart is declared in omlx's [audio] extra, not in mlx-audio
    system libexec/"bin/pip", "install", "python-multipart>=0.0.5"

    # Patch the macOS arm64 xgrammar wheel so its native binding loads.
    # The 0.1.32+ wheel ships libxgrammar_bindings.dylib with
    # @rpath/libtvm_ffi.dylib but no LC_RPATH pointing at where tvm_ffi
    # installs its native lib, and the dist-info is missing a RECORD
    # entry for the dylib so tvm_ffi's manifest-based lookup fails.
    # Both manifest as RuntimeError("Cannot find library: ...") at
    # `import xgrammar`, which crashes /admin/api/grammar/parsers and
    # hides the Reasoning Parser dropdown. Tracking upstream:
    # jundot/omlx#1005.
    if build.with?("grammar")
      py = libexec/"bin/python"
      site = Utils.safe_popen_read(py, "-c",
                                   "import site; print(site.getsitepackages()[0])").chomp
      dylib = "#{site}/xgrammar/libxgrammar_bindings.dylib"
      dist  = Dir["#{site}/xgrammar-*.dist-info"].first
      tvmlib = Utils.safe_popen_read(py, "-c",
        "import os, tvm_ffi; print(os.path.join(os.path.dirname(tvm_ffi.__file__), 'lib'))").chomp

      if File.exist?(dylib)
        rpaths = Utils.safe_popen_read("/usr/bin/otool", "-l", dylib)
        unless rpaths.include?(tvmlib)
          system "/usr/bin/install_name_tool", "-add_rpath", tvmlib, dylib
          system "/usr/bin/codesign", "--force", "--sign", "-", dylib
        end
      end

      if dist
        record = "#{dist}/RECORD"
        unless File.exist?(record) && File.read(record).include?("libxgrammar_bindings.dylib")
          File.open(record, "a") { |f| f.puts "xgrammar/libxgrammar_bindings.dylib,," }
        end
      end
    end

    bin.install_symlink Dir[libexec/"bin/omlx"]
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/omlx --version")
  end
end

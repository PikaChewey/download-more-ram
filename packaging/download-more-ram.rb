# Homebrew formula (tap: PikaChewey/homebrew-tap). Builds from source, so no notarization is needed for
# the CLI. Fill in url/sha256 after the v1.1.0 tag exists (publishing needs Bryan's yes).
class DownloadMoreRam < Formula
  desc "Make macOS apps give memory back via the kernel's own pressure signal, with measured receipts"
  homepage "https://github.com/PikaChewey/download-more-ram"
  url "https://github.com/PikaChewey/download-more-ram/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256_OF_THE_TAG_TARBALL"
  license "MIT"
  depends_on :macos => :sonoma
  depends_on arch: :arm64

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "ram"
    system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "ram-helper"
    bin.install ".build/release/ram"
    libexec.install ".build/release/ram-helper"
    # `ram helper install` looks for ram-helper next to the resolved ram binary.
    (bin/"ram-helper").make_symlink libexec/"ram-helper"
  end

  def caveats
    <<~EOS
      Downloads use macOS's root-only memory-pressure switch. Install the helper once:
        sudo ram helper install
      Then:
        ram doctor
        ram download
    EOS
  end

  test do
    assert_match "ram 1.1.0", shell_output("#{bin}/ram --version")
  end
end

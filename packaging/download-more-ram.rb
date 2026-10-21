# Homebrew formula for a tap (PikaChewey/homebrew-tap, not created yet). Builds the CLI from source, so no
# notarization is needed. url/sha256 are the published v1.1.0 tag.
class DownloadMoreRam < Formula
  desc "Make macOS apps give memory back via the kernel's own pressure signal, with measured receipts"
  homepage "https://github.com/PikaChewey/download-more-ram"
  url "https://github.com/PikaChewey/download-more-ram/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "27c595d7b9676629d4018e36d551b44b500c5ed5926ec1bb4216717c346fc8ed"
  license "MIT"
  depends_on xcode: ["16.0", :build]
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

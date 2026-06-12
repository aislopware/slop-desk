// aislopdesk-hid-bridge — the small ROOT component of the virtual-HID keyboard path (lets the remote
// client type into a macOS SecurityAgent login/password dialog, which Secure Event Input blocks for the
// synthetic CGEvents aislopdesk-videohostd normally posts; HID-device input is NOT blocked).
//
// WHY a separate process: the Karabiner-DriverKit-VirtualHIDDevice daemon's report socket is root-only,
// but videohostd must stay a normal-user process (its Screen-Recording / Accessibility TCC grants are
// per-user). So this tiny bridge runs as root, owns the Karabiner client, and accepts 8-byte HID boot
// keyboard reports from videohostd over a localhost UDP socket — the exact reports
// `VirtualHIDKeyboard`/`HIDKeyboardState` build (`[modifiers, 0, k1..k6]`). It just parses + forwards
// them to the virtual keyboard. Stateless + idempotent: each report is the FULL key state, so a dropped
// or reordered datagram self-corrects on the next one.
//
// Run as root (launchd or `sudo aislopdesk-hid-bridge`). Built against the Karabiner C++ client lib by
// hid-bridge/build.sh.
#include <atomic>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <thread>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>
#include <pqrs/local_datagram.hpp>

namespace {
std::atomic<bool> exit_flag(false);
std::atomic<bool> ready_flag(false);
constexpr uint16_t kPort = 9100;  // 127.0.0.1:9100 — must match InputInjector's AISLOPDESK_HID_BRIDGE_PORT
}  // namespace

int main() {
  std::signal(SIGINT, [](int) { exit_flag = true; });
  std::signal(SIGTERM, [](int) { exit_flag = true; });

  pqrs::dispatcher::extra::initialize_shared_dispatcher();
  auto client = std::make_unique<pqrs::karabiner::driverkit::virtual_hid_device_service::client>();

  client->connected.connect([&client] {
    std::cerr << "[hid-bridge] connected; initializing virtual keyboard" << std::endl;
    pqrs::karabiner::driverkit::virtual_hid_device_service::virtual_hid_keyboard_parameters p;
    p.set_country_code(pqrs::hid::country_code::us);
    client->async_virtual_hid_keyboard_initialize(p);
  });
  client->connect_failed.connect([](auto&& e) { std::cerr << "[hid-bridge] connect_failed " << e << std::endl; });
  client->error_occurred.connect([](auto&& e) { std::cerr << "[hid-bridge] error " << e << std::endl; });
  client->virtual_hid_keyboard_ready.connect([](auto&& ready) {
    if (ready && !ready_flag.exchange(true)) std::cerr << "[hid-bridge] virtual keyboard READY" << std::endl;
  });
  client->async_start();

  // UDP listener for the 8-byte HID boot reports videohostd sends.
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) { std::cerr << "[hid-bridge] socket() failed" << std::endl; return 1; }
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(kPort);
  if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
    std::cerr << "[hid-bridge] bind() to 127.0.0.1:" << kPort << " failed (already running?)" << std::endl;
    return 1;
  }
  std::cerr << "[hid-bridge] listening on 127.0.0.1:" << kPort << std::endl;

  std::thread recv_thread([&client, fd] {
    namespace vd = pqrs::karabiner::driverkit::virtual_hid_device_driver;
    uint8_t buf[64];
    while (!exit_flag) {
      ssize_t n = recv(fd, buf, sizeof(buf), 0);
      if (n < 0) { if (exit_flag) break; continue; }
      if (n != 8 || !ready_flag) continue;  // expect exactly an 8-byte report; keyboard must be up
      vd::hid_report::keyboard_input report;
      const uint8_t mod = buf[0];
      if (mod & 0x01) report.modifiers.insert(vd::hid_report::modifier::left_control);
      if (mod & 0x02) report.modifiers.insert(vd::hid_report::modifier::left_shift);
      if (mod & 0x04) report.modifiers.insert(vd::hid_report::modifier::left_option);
      if (mod & 0x08) report.modifiers.insert(vd::hid_report::modifier::left_command);
      for (int i = 2; i < 8; ++i) {
        if (buf[i] != 0) report.keys.insert(buf[i]);
      }
      client->async_post_report(report);
    }
  });

  while (!exit_flag) std::this_thread::sleep_for(std::chrono::milliseconds(100));

  shutdown(fd, SHUT_RDWR);
  close(fd);
  recv_thread.join();
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  client = nullptr;
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
  return 0;
}

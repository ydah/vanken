# frozen_string_literal: true

require "spec_helper"
require "vanken/capture/privileges"

RSpec.describe Vanken::Capture::Privileges do
  it "clears supplementary groups before irreversibly dropping gid and uid" do
    expect(Process).to receive(:groups=).with([]).ordered
    expect(Process::GID).to receive(:change_privilege).with(1001).ordered
    expect(Process::UID).to receive(:change_privilege).with(1000).ordered
    allow(Process).to receive_messages(uid: 1000, euid: 1000, gid: 1001, egid: 1001, groups: [])
    expect(described_class.drop!(1000, 1001)).to be(true)
  end

  it "refuses success when any real or effective identity remains elevated" do
    allow(Process).to receive(:groups=)
    allow(Process::GID).to receive(:change_privilege)
    allow(Process::UID).to receive(:change_privilege)
    allow(Process).to receive_messages(uid: 1000, euid: 0, gid: 1001, egid: 1001, groups: [])
    expect { described_class.drop!(1000, 1001) }.to raise_error(Vanken::Capture::Privileges::Error)
  end
end

# frozen_string_literal: true

require "spec_helper"
require "vanken/gateway/interfaces"
require "vanken/gateway/capture_filter"
require "vanken/gateway/live_capture"

RSpec.describe "capture gateway contracts" do
  it "returns serializable interface metadata and validates interface names" do
    interfaces = Vanken::Gateway::Interfaces.list
    expect(interfaces).not_to be_empty
    expect(interfaces.first).to include(:name, :linktype, :up, :running, :loopback)
    expect { JSON.generate(interfaces) }.not_to raise_error
    expect { Vanken::Gateway::Interfaces.find("not-an-interface; touch /tmp/never") }.to raise_error(Vanken::Gateway::Interfaces::NotFound)
  end

  it "compiles verified capture filters and reports syntax position" do
    program = Vanken::Gateway::CaptureFilter.compile("tcp port 443", linktype: 1)
    expect(program.disassemble).not_to be_empty
    expect { Vanken::Gateway::CaptureFilter.compile("tcp port (", linktype: 1) }.to raise_error(Vanken::Gateway::CaptureFilter::Error) { |e| expect(e.position).to be_a(Integer) }
  end

  it "keeps redhound operational errors behind the gateway" do
    allow(Redhound::Capture).to receive(:open).and_raise(Redhound::PermissionDenied, "not permitted")
    interface = Vanken::Gateway::Interfaces.list.first[:name]
    expect { Vanken::Gateway::LiveCapture.open(interface: interface) }.to raise_error(Vanken::Gateway::LiveCapture::Error) { |e| expect(e.code).to eq("permission_denied") }
  end
end

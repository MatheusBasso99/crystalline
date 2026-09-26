require "spec"
require "file_utils"
require "../src/crystalline/project"

describe Crystalline::Project do
  it "does not match unrelated files once dependencies are known" do
    root = File.join(Dir.tempdir, "crystalline-project-spec-#{Random::Secure.hex(8)}")
    begin
      Dir.mkdir_p(root)
      project = Crystalline::Project.new(URI.parse("file://#{root}"))
      dependency_path = File.join(root, "src", "main.cr")
      unrelated_path = File.join(root, "scratch.cr")
      Dir.mkdir_p(File.dirname(dependency_path))
      File.write(dependency_path, "")
      File.write(unrelated_path, "")

      project.dependencies << dependency_path

      Crystalline::Project.best_fit_for_file([project], URI.parse("file://#{dependency_path}")).should eq(project)
      Crystalline::Project.best_fit_for_file([project], URI.parse("file://#{unrelated_path}")).should be_nil

      # Lightweight queries may opt into a pure path-based fit.
      Crystalline::Project.best_fit_for_file([project], URI.parse("file://#{unrelated_path}"), require_dependency: false).should eq(project)
      Crystalline::Project.best_fit_for_file([project], URI.parse("file://#{dependency_path}"), require_dependency: false).should eq(project)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "adds the requires of a compile that failed to the known dependencies" do
    project = Crystalline::Project.new(URI.parse("file:///project"))
    project.record_requires(["/project/src/main.cr", "/project/src/a.cr"], complete: true)
    project.outsiders << "/project/src/b.cr"

    # The compile stopped at an error after b.cr: a.cr is not dropped for it.
    project.record_requires(["/project/src/main.cr", "/project/src/b.cr"], complete: false)
    project.dependencies.should eq(Set{"/project/src/main.cr", "/project/src/a.cr", "/project/src/b.cr"})
    project.outsiders.should be_empty

    # A compile that went through knows them all.
    project.record_requires(["/project/src/main.cr"], complete: true)
    project.dependencies.should eq(Set{"/project/src/main.cr"})
  end
end

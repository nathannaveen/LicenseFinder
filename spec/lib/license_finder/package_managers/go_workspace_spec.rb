require 'spec_helper'

module LicenseFinder
  describe GoWorkspace do
    let(:options) { {} }
    let(:logger) { double(:logger, active: nil) }
    let(:project_path) { '/Users/pivotal/workspace/loggregator'}
    subject { GoWorkspace.new(options.merge(project_path: Pathname(project_path), logger: logger)) }

    describe '#go_list' do

      let(:go_list_output) {
        <<HERE
encoding/json
github.com/onsi/ginkgo
HERE
      }

      before do
        allow(Dir).to receive(:chdir).with(Pathname.new project_path) { |&b| b.call() }
        allow(FileTest).to receive(:exist?).and_return(false)
        allow(FileTest).to receive(:exist?).with(File.join(project_path, '.envrc')).and_return(true)
      end

      it 'changes the directory' do
        subject.send(:go_list)

        expect(Dir).to have_received(:chdir)
      end

      it 'returns the skip the standard libs and return lines of the output' do
        allow(subject).to receive(:capture).with('go list -f \'{{join .Deps "\n"}}\' ./...').and_return([go_list_output, true])
        packages = subject.send(:go_list)
        expect(packages.count).to eq(1)
        expect(packages.first).to eq('github.com/onsi/ginkgo')
      end

      it 'sets gopath to the envrc path' do
        allow(subject).to receive(:capture).with('go list -f \'{{join .Deps "\n"}}\' ./...') {
          expect(ENV['GOPATH']).to be_nil
          ['', true]
        }

        subject.send(:go_list)
      end
    end

    describe '#git_modules' do
      before do
        allow(FileTest).to receive(:exist?).and_return(false)
        allow(FileTest).to receive(:exist?).with('/Users/pivotal/workspace/loggregator/.envrc').and_return(true)
        allow(Dir).to receive(:chdir).with(Pathname.new '/Users/pivotal/workspace/loggregator') { |&b| b.call() }
      end

      context 'if git submodule status fails' do
        before do
          allow(subject).to receive(:capture).with('git submodule status').and_return(['', false])
        end

        it 'should raise an exception' do
          expect { subject.send(:git_modules) }.to raise_exception(/git submodule status failed/)
        end
      end

      context 'if git submodule status succeeds' do
        let(:git_submodule_status_output) {
          <<HERE
1993eafbef57be29ee8f5eb9d26a22f20ff3c207 src/github.com/GaryBoone/GoStats (heads/master)
55eb11d21d2a31a3cc93838241d04800f52e823d src/github.com/Sirupsen/logrus (v0.7.3)
HERE
        }

        before do
          allow(subject).to receive(:capture).with('git submodule status').and_return([git_submodule_status_output, true])
        end

        it 'should return the filtered submodules' do
          submodules = subject.send(:git_modules)
          expect(submodules.count).to eq(2)
          expect(submodules.first.install_path).to eq('/Users/pivotal/workspace/loggregator/src/github.com/GaryBoone/GoStats')
          expect(submodules.first.revision).to eq('1993eafbef57be29ee8f5eb9d26a22f20ff3c207')
        end
      end
    end

    describe '#current_packages' do
      let(:git_modules_output) {
        [GoWorkspace::Submodule.new("/Users/pivotal/workspace/loggregator/src/bitbucket.org/kardianos/osext", "b8a35001b773c267e")]
      }

      let(:go_list_output) {
        [
         "bitbucket.org/kardianos/osext",
         "bitbucket.org/kardianos/osext/foo",
        ]
      }


      before do
        allow(FileTest).to receive(:exist?).and_return(true)

        allow(Dir).to receive(:chdir).with(Pathname('/Users/pivotal/workspace/loggregator')) { |&block| block.call }
        allow(subject).to receive(:go_list).and_return(go_list_output)
        allow(subject).to receive(:git_modules).and_return(git_modules_output)
      end

      describe 'should return an array of go packages' do
        it 'provides package names' do
          packages = subject.current_packages
          expect(packages.count).to eq(1)
          first_package = packages.first
          expect(first_package.name).to eq 'bitbucket.org/kardianos/osext'
          expect(first_package.version).to eq 'b8a3500'
          expect(first_package.install_path).to eq '/Users/pivotal/workspace/loggregator/src/bitbucket.org/kardianos/osext'
        end

        it 'should filter the subpackages' do
          packages = subject.current_packages
          packages = packages.select { |p| p.name.include?("bitbucket.org") }
          expect(packages.count).to eq(1)
        end

        context 'when requesting the full version' do
          let(:options) { { go_full_version:true } }
          it 'list the dependencies with full version' do
            expect(subject.current_packages.map(&:version)).to eq ["b8a35001b773c267e"]
          end
        end

        context 'when the deps are in a vendor directory' do
          let(:git_modules_output) {
            [GoWorkspace::Submodule.new("/Users/pivotal/workspace/loggregator/vendor/src/bitbucket.org/kardianos/osext", "b8a35001b773c267e")]
          }

          it 'reports the right import path' do
            expect(subject.current_packages.map(&:name)).to include('bitbucket.org/kardianos/osext')
          end

          it 'reports the right install path' do
            expect(subject.current_packages.map(&:install_path)).to include('/Users/pivotal/workspace/loggregator/vendor/src/bitbucket.org/kardianos/osext')
          end
        end

        context 'when only the subpackage is being used' do
          let(:go_list_output) {
            [
             "bitbucket.org/kardianos/osext/foo",
            ]
          }

          it 'returns the top level repo name as the import path' do
            packages = subject.current_packages
            expect(packages.map(&:name)).to eq(['bitbucket.org/kardianos/osext'])
          end
        end

        context 'when only the subpackage is being used' do
          let(:git_modules_output) {
            [GoWorkspace::Submodule.new("/Users/pivotal/workspace/loggregator/vendor/src/github.com/onsi/foo", "e762c377b10053a8b"),
             GoWorkspace::Submodule.new("/Users/pivotal/workspace/loggregator/vendor/src/github.com/onsi/foobar", "b8a35001b773c267e")]
          }

          let(:go_list_output) {
            [
             "github.com/onsi/foo",
             "github.com/onsi/foobar",
            ]
          }

          it 'returns the top level repo name as the import path' do
            packages = subject.current_packages
            expect(packages.map(&:name)).to eq(['github.com/onsi/foo', 'github.com/onsi/foobar'])
          end
        end
      end
    end

    describe '#package_path' do
      before do
        allow(FileTest).to receive(:exist?).and_return(true)
      end

      it 'returns the package_path' do
        expect(subject.package_path).to eq Pathname('/Users/pivotal/workspace/loggregator')
      end
    end

    describe '#active?' do
      let(:envrc)   { '/Users/pivotal/workspace/loggregator/.envrc' }

      before do
        allow(FileTest).to receive(:exist?).and_return(false)
      end

      it 'returns true when .envrc contains GOPATH' do
        allow(FileTest).to receive(:exist?).with(envrc).and_return(true)
        allow(IO).to receive(:read).with(Pathname(envrc)).and_return('export GOPATH=/foo/bar')
        expect(subject.active?).to eq(true)
      end

      it 'returns true when .envrc contains GO15VENDOREXPERIMENT' do
        allow(FileTest).to receive(:exist?).with(envrc).and_return(true)
        allow(IO).to receive(:read).with(Pathname(envrc)).and_return('export GO15VENDOREXPERIMENT=1')
        expect(subject.active?).to eq(true)
      end

      it 'returns false when .envrc does not contain GOPATH or GO15VENDOREXPERIMENT' do
        allow(FileTest).to receive(:exist?).with(envrc).and_return(true)
        allow(IO).to receive(:read).with(Pathname(envrc)).and_return('this is not an envrc file')
        expect(subject.active?).to eq(false)
      end

      it 'returns false when .envrc does not exist' do
        expect(subject.active?).to eq(false)
      end

      it 'logs the active state' do
        expect(logger).to receive(:active)
        subject.active?
      end

      context 'when Godep is present' do
        let(:godeps)   { '/Users/pivotal/workspace/loggregator/Godeps/Godeps.json' }

        it 'should prefer Godeps over go_workspace' do
          allow(FileTest).to receive(:exist?).with(Pathname(godeps)).and_return(true)
          expect(subject.active?).to eq(false)
        end
      end

      context 'when .envrc is present in a parent directory' do
        subject {
          GoWorkspace.new(options.merge(project_path: Pathname('/Users/pivotal/workspace/loggregator/src/github.com/foo/bar'),
                                        logger: logger))
        }

        it 'returns true' do
          allow(FileTest).to receive(:exist?).with(envrc).and_return(true)
          allow(IO).to receive(:read).with(Pathname(envrc)).and_return('export GOPATH=/foo/bar')
          expect(subject.active?).to be true
        end
      end
    end
  end
end

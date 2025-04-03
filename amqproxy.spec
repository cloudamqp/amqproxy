Name:    amqproxy
Summary: Connection and channel pool for AMQP connections
Version: 1.0.0
Release: 1%{?dist}

License: Apache 2.0
BuildRequires: systemd-rpm-macros crystal help2man
URL: https://github.com/cloudamqp/amqproxy
Source: amqproxy.tar.gz

%description
An AMQP proxy that reuses upstream connections and channels

%prep
%setup -qn amqproxy

%check

%build
make

%install
make install DESTDIR=%{buildroot} UNITDIR=%{_unitdir}

%post
%systemd_post %{name}.service

%preun
%systemd_preun %{name}.service

%postun
%systemd_postun_with_restart %{name}.service

%files
%{_bindir}/%{name}
%{_unitdir}/%{name}.service
%{_mandir}/man1/*
%config(noreplace) %{_sysconfdir}/%{name}.ini
%doc README.md
%doc %{_docdir}/%{name}/changelog
%license LICENSE

%changelog
* Thu Nov 24 2022 CloudAMQP <contact@cloudamqp.com>
- Initial version of the package

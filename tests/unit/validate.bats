#!/usr/bin/env bats
#
# Unit tests for lib/validate.sh
#
# shellcheck shell=bash

load ../helpers.bash

source "${BATS_TEST_DIRNAME}/../../lib/common.sh"
source "${BATS_TEST_DIRNAME}/../../lib/validate.sh"

@test "username: accepts valid names" {
    run rs_validate_username root
    [ "$status" -eq 0 ]

    run rs_validate_username deploy-user_42
    [ "$status" -eq 0 ]
}

@test "username: rejects invalid names" {
    run rs_validate_username "Bob"
    [ "$status" -ne 0 ]

    run rs_validate_username ""
    [ "$status" -ne 0 ]

    run rs_validate_username "has space"
    [ "$status" -ne 0 ]
}

@test "password: rejects short passwords" {
    run rs_validate_password "short"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at least 8 characters"* ]]
}

@test "password: rejects quotes and whitespace" {
    run rs_validate_password "has space123"
    [ "$status" -ne 0 ]

    run rs_validate_password "quote\"pass1"
    [ "$status" -ne 0 ]
}

@test "password: accepts long enough password" {
    run rs_validate_password "CorrectHorseBatteryStaple1"
    [ "$status" -eq 0 ]
}

@test "port: boundary values" {
    run rs_validate_port 1
    [ "$status" -eq 0 ]

    run rs_validate_port 65535
    [ "$status" -eq 0 ]

    run rs_validate_port 0
    [ "$status" -ne 0 ]

    run rs_validate_port 65536
    [ "$status" -ne 0 ]

    run rs_validate_port "abc"
    [ "$status" -ne 0 ]
}

@test "ssh key: accepts openssh public keys" {
    local key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    run rs_validate_ssh_key "${key}"
    [ "$status" -eq 0 ]

    run rs_validate_ssh_key "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ fake"
    [ "$status" -eq 0 ]
}

@test "ssh key: rejects garbage" {
    run rs_validate_ssh_key "not a key at all"
    [ "$status" -ne 0 ]

    run rs_validate_ssh_key "ssh-rsa !!!notbase64!!!"
    [ "$status" -ne 0 ]
}

@test "url: accepts http/https/ftp" {
    run rs_validate_url "https://example.com/image.img"
    [ "$status" -eq 0 ]

    run rs_validate_url "ftp://mirror.example/file"
    [ "$status" -eq 0 ]
}

@test "url: rejects garbage and embedded quotes" {
    run rs_validate_url "example.com/no-scheme"
    [ "$status" -ne 0 ]

    run rs_validate_url 'https://example.com/a"b'
    [ "$status" -ne 0 ]

    run rs_validate_url "https://example.com/a b"
    [ "$status" -ne 0 ]
}

@test "url: accepts magnet links for torrents" {
    run rs_validate_url "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
    [ "$status" -eq 0 ]
}

@test "lang: accepts and rejects language tags" {
    run rs_validate_lang "en-us"
    [ "$status" -eq 0 ]

    run rs_validate_lang "zh-cn"
    [ "$status" -eq 0 ]

    run rs_validate_lang "notalang"
    [ "$status" -ne 0 ]
}

@test "hold: accepts 0/1/2 only" {
    run rs_validate_hold 0
    [ "$status" -eq 0 ]

    run rs_validate_hold 2
    [ "$status" -eq 0 ]

    run rs_validate_hold 3
    [ "$status" -ne 0 ]
}

@test "distro version: accepts dotted numbers and rolling" {
    run rs_validate_distro_version "12"
    [ "$status" -eq 0 ]

    run rs_validate_distro_version "24.04"
    [ "$status" -eq 0 ]

    run rs_validate_distro_version "rolling"
    [ "$status" -eq 0 ]

    run rs_validate_distro_version "12.04.1-beta"
    [ "$status" -ne 0 ]
}

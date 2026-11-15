#lang info

;;; edit —— 终端编辑器，多 collection 包。
;;;
;;; core/ 与 edit-tui/ 各自是 collection；包级依赖与元数据只放在这里。
;;;
;;; 安装（不经过 Racket 包管理）：
;;;   scripts/install.sh          # copy 到 /usr/local/lib/edit 并编译
;;;   scripts/install.sh --link   # 原地编译源码树
;;; 卸载：
;;;   scripts/uninstall.sh
;;;
;;; 本文件及子目录 info.rkt 只作为可选的 raco pkg 元数据保留；
;;; 安装脚本不会执行 raco pkg install / raco setup。

(define collection 'multi)

(define version "0.1")
(define pkg-desc "Terminal editor")
(define pkg-authors '("lu96"))
(define license 'MIT)

(define deps '("base"
               "racket-lib"
               "html-parsing"
               "racket-tui"))
(define build-deps '("rackunit-lib"))

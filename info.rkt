#lang info

;;; edit —— 终端编辑器，多 collection 包。
;;;
;;; core/ 与 edit-tui/ 各自是 collection；包级依赖与元数据只放在这里。
;;;
;;; 推荐用脚本安装（会同时处理 wrapper / PATH / 卸载记录）：
;;;   scripts/install.sh
;;;   scripts/install.sh --copy
;;; 手动安装（不生成 wrapper）：
;;;   raco pkg install --link --auto "$PWD"
;;; 卸载：
;;;   scripts/uninstall.sh
;;;   raco pkg remove edit

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

#lang info

;;; edit —— 终端编辑器，多 collection 包。
;;;
;;; core/ 与 edit-tui/ 各自是 collection；包级依赖与元数据只放在这里。
;;;
;;; 开发安装（源码原地，改完直接生效；路径须是绝对路径）：
;;;   raco pkg install --link --auto "$PWD"
;;; 快照安装（复制进用户 scope）：
;;;   raco pkg install --copy --auto "$PWD"
;;; 卸载：
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

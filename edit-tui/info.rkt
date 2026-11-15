#lang info

;;; edit-tui collection 信息。
;;;
;;; 启动器由 raco setup 生成：racket-launcher-libraries 里的模块被
;;; `-l` 加载，模块的 `module+ main` 负责进入 TUI 主循环。
;;; 安装后启动器位于 <addon-dir>/bin/edit-tui。
;;;
;;; 不叫 edit：Debian 的 /usr/bin/edit 已指向 run-mailcap，同名会被
;;; /usr/bin 抢先命中（除非把 Racket 的 bin 目录放在 PATH 前面）。

(define name "edit-tui")
(define racket-launcher-names '("edit-tui"))
(define racket-launcher-libraries '("edit.rkt"))

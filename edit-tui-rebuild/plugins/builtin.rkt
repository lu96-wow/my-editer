#lang racket

;;; layer  : plugins
;;; effect : 无（纯装配）
;;;
;;; 内置插件集 + 组合好的 default-env。
;;;
;;;   core-env          bootstrap/defaults.rkt（只有框架）
;;;   default-plugins   filetree + resource（侧栏 / 列表，属于“编辑器骨架”）
;;;   default-env       core-env + default-plugins
;;;   editor-plugins    default + highlight + completion + docs（面向写代码）
;;;   editor-env        core-env + editor-plugins
;;;
;;; demo / 测试用 default-env；想只要框架就只用 core-env（见 test/plugin-detach.rkt）。
;;; 新插件加进这里即可，不需要改 bootstrap。

(provide default-plugins
         default-env
         editor-plugins
         editor-env)

(require "../bootstrap/defaults.rkt"
         "../env/plugin.rkt"
         "filetree/plugin.rkt"
         "resource/plugin.rkt"
         "highlight/plugin.rkt"
         "completion/plugin.rkt"
         "docs/plugin.rkt")

(define (default-plugins)
  (list (filetree-plugin)
        (resource-plugin)))

(define default-env
  (plugins-env core-env (default-plugins)))

;;; ════════════════ 面向写代码的一组（高亮 + 补全 + 文档） ════════════════

(define (editor-plugins)
  (append (default-plugins)
          (list (highlight-plugin)
                (completion-plugin)
                (docs-plugin))))

(define editor-env
  (plugins-env core-env (editor-plugins)))

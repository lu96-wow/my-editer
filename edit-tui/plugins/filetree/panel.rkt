#lang racket

;;; plugins/filetree/panel.rkt —— 文件树面板（buffer 支撑）
;;; layer  : plugins/filetree
;;; effect : **IO**：写 *filetree* buffer（panel-sync-buffer!）

;;; 只保留三件事，装配动作全在 effects/panel.rkt：
;;;   sync    : 每帧从磁盘生成行 -> panel-sync-buffer!
;;;   lines   : 委托 projection/filetree（纯 / IO 投影）
;;;   view    : 面板自己的 view-id（插件切片 store['filetree]）
;;;
;;; 身份（name / role / mode）与安装动作在 plugins/filetree/plugin.rkt。
;;;
;;; IO 读取在 sync / 命令里做，State 只存 view-id / expanded / width。

(provide sync-filetree-panel! filetree-panel-view)
(provide (all-from-out "lines.rkt"))

(require "../../model/state.rkt"
         "model.rkt"
         "../../effects/engine.rkt"
         "lines.rkt"
         "scan.rkt"
         "../../effects/panel.rkt")

(define (filetree-panel-view state)
  (filetree-view (plugin-state state 'filetree (empty-filetree))))

(define (sync-filetree-panel! state engine)
  (define vid (filetree-panel-view state))
  ;; 与别的面板共用一块位置时，被挡住就不扫盘 / 不重建 buffer。
  (when (and vid (panel-visible? state vid))
    (define lines (filetree-lines state dir-entries))
    (panel-sync-buffer! engine state vid
                        #:texts (map filetree-line-text lines)
                        #:faces (map filetree-line-face lines))))

# frozen_string_literal: true

Rails.application.routes.draw do
  devise_for :users, skip: [ :registrations ]

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  namespace :admin do
    resources :users, except: :destroy do
      member do
        patch :deactivate
        patch :activate
        patch :resend_invitation
      end
      resources :user_work_patterns, only: %i[new create edit update] do
        member do
          patch :deactivate
          patch :activate
        end
      end
      resources :leave_balances, only: %i[new create edit update]   # ← 追加（フラット controller）
    end
    resources :work_patterns, except: :destroy do
      member do
        patch :deactivate
        patch :activate
      end
    end
    resources :leave_types, except: :destroy do
      member do
        patch :deactivate
        patch :activate
      end
    end
    resources :company_calendars, except: :show
    namespace :company_calendars do
      resource :import, only: %i[new create]
      resource :legal_holiday_generation, only: %i[new create]
    end
    resources :reason_templates, except: :destroy do
      member do
        patch :deactivate
        patch :activate
      end
    end
    resource :organization_setting, only: %i[edit update] # singular（0b-5 設計 §4）
  end

  resource :clocking, only: [] do
    post :clock_in
    post :clock_out
  end

  resources :proxy_clockings, only: %i[index] do
    member do
      post :clock_in    # :id = 対象社員 id
      post :clock_out
    end
  end

  resources :leave_requests, only: %i[index new create] do
    collection { get :preview }   # ← Task 14 で使用（ここで定義しておく）
    member { patch :cancel; patch :request_withdrawal }
  end

  resources :clock_change_requests, only: %i[index new create] do
    member { patch :cancel; patch :request_withdrawal }
  end

  resources :holiday_work_requests, only: %i[index new create] do
    member { patch :cancel }
  end

  resources :approval_assignments, only: %i[index] do
    member do
      patch :approve
      patch :reject
    end
  end

  resources :monthly_attendance_summaries, only: %i[index show] do
    collection do
      patch :bulk_finalize
      get :summary_csv
    end
    member do
      patch :submit
      patch :finalize
      patch :defer
      get :detail_csv
    end
  end

  resources :notifications, only: %i[index update]
  resource :notification_preferences, only: %i[edit update] # singular（current_user 自身の設定）

  root "home#show"
end

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

  root "home#show"
end

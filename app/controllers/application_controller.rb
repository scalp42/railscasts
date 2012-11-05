class ApplicationController < ActionController::Base

  protect_from_forgery
  
  # TODO authorization blocks Devise sign in and sign up 
  #enable_authorization do |exception|
  #  logger.debug exception
  #  redirect_to root_url, :alert => exception.message
  #end

  private

  def user_for_paper_trail
    current_user && current_user.id
  end

  def current_user
    @current_user ||= User.find_by_token(cookies[:token]) if cookies[:token]
  end
  helper_method :current_user

  def redirect_to_target_or_default(default, *options)
    redirect_to(session[:return_to] || default, *options)
    session[:return_to] = nil
  end

  def store_target_location
    session[:return_to] = request.url
  end
end
